// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStablecoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStablecoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    /**
     * @param collateralSeed The seed used to determine the collateral type
     * @param amountCollateral The amount of collateral to deposit
     */
    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    /**
     *
     * @param amountDsc The amount of DSC to mint
     * @param addressSeed The seed used to pick a user that has deposited collateral
     */
    function mintDsc(uint256 amountDsc, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        uint256 maxDscForCollateral =
            (collateralValueInUsd * dsce.getLiquidationThreshold()) / dsce.getLiquidationPrecision();
        uint256 allowance = maxDscForCollateral > totalDscMinted ? maxDscForCollateral - totalDscMinted : 0;
        // Roughly half of the attempts go past the user's allowance, to check the engine refuses them.
        amountDsc = bound(amountDsc, 1, 2 * allowance + 1);

        vm.prank(sender);
        try dsce.mintDsc(amountDsc) {
            timesMintIsCalled++;
        } catch (bytes memory reason) {
            // Minting past the collateral threshold must revert; any other revert is a real failure.
            if (bytes4(reason) != DSCEngine.DSCEngine__BreaksHealthFactor.selector) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    /**
     *
     * @param collateralSeed The seed used to determine the collateral type
     * @param amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));

        // Only redeem what keeps the user at or above the minimum health factor.
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(msg.sender);
        if (totalDscMinted > 0) {
            uint256 threshold = dsce.getLiquidationThreshold();
            uint256 requiredCollateralInUsd =
                (totalDscMinted * dsce.getLiquidationPrecision() + threshold - 1) / threshold;
            if (collateralValueInUsd <= requiredCollateralInUsd) {
                return;
            }
            uint256 excessCollateral =
                dsce.getTokenAmountFromUsd(address(collateral), collateralValueInUsd - requiredCollateralInUsd);
            if (excessCollateral < maxCollateralToRedeem) {
                maxCollateralToRedeem = excessCollateral;
            }
        }

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        vm.prank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    /**
     *
     * @param amountDsc The amount of DSC to mint
     */
    function burnDsc(uint256 amountDsc) public {
        // Can only burn DSC that is both held and owed by the caller
        (uint256 totalDscMinted,) = dsce.getAccountInformation(msg.sender);
        uint256 maxDscToBurn = dsc.balanceOf(msg.sender);
        if (totalDscMinted < maxDscToBurn) {
            maxDscToBurn = totalDscMinted;
        }
        amountDsc = bound(amountDsc, 0, maxDscToBurn);
        if (amountDsc == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dsc.approve(address(dsce), amountDsc);
        dsce.burnDsc(amountDsc);
        vm.stopPrank();
    }

    /**
     *
     * @param collateralSeed The seed used to determine the collateral type
     * @param userToBeLiquidated The user to be liquidated
     */
    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        uint256 userHealthFactor = dsce.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        dsce.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    /**
     *
     * @param amountDsc The amount of DSC to transfer
     * @param to The address to transfer the DSC to
     */
    function transferDsc(uint256 amountDsc, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dsc.transfer(to, amountDsc);
    }

    /**
     *
     * @param newPrice The new price to set for the collateral
     * @param collateralSeed The seed used to determine the collateral type
     */
    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /**
     *
     * @param collateralSeed The seed used to determine the collateral type
     */
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
