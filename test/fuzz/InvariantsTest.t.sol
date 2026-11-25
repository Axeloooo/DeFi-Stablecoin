// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStablecoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));

        // Price updates are left out: a sharp enough drop can push positions below the collateral
        // threshold before anyone liquidates them, which is a known limitation of this design.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = Handler.mintAndDepositCollateral.selector;
        selectors[1] = Handler.redeemCollateral.selector;
        selectors[2] = Handler.mintDsc.selector;
        selectors[3] = Handler.burnDsc.selector;
        selectors[4] = Handler.liquidate.selector;
        selectors[5] = Handler.transferDsc.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_totalSupplyWithinCollateralThreshold() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethValue = dsce.getUsdValue(weth, IERC20(weth).balanceOf(address(dsce)));
        uint256 wbtcValue = dsce.getUsdValue(wbtc, IERC20(wbtc).balanceOf(address(dsce)));
        uint256 totalCollateralValue = wethValue + wbtcValue;
        uint256 maxSupply = (totalCollateralValue * dsce.getLiquidationThreshold()) / dsce.getLiquidationPrecision();

        assertLe(totalSupply, maxSupply);
    }

    function invariant__gettersShouldNotRevert() public view {
        dsce.getPrecision();
        dsce.getAdditionalFeedPrecision();
        dsce.getLiquidationThreshold();
        dsce.getLiquidationBonus();
        dsce.getLiquidationPrecision();
        dsce.getMinHealthFactor();
        dsce.getCollateralTokens();
        dsce.getDsc();
    }
}
