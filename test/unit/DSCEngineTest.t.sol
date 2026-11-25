// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "../mock/MockV3Aggregator.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStablecoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    address public LIQUIDATOR = makeAddr("liquidator");
    // 10 WETH at $2,000 is $20,000 of collateral; at 200% collateralization that backs at most 10,000 DSC.
    uint256 public constant MAX_DSC_FOR_COLLATERAL = 10_000e18;
    int256 public constant ETH_USD_PRICE_AFTER_CRASH = 1800e8;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(1000e18);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanMintDsc() public depositedCollateral {
        uint256 amountToMint = 1000e18;
        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
        assertEq(dsc.balanceOf(USER), amountToMint);
    }

    function testRevertsIfMintAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 500e18);
        dsce.burnDsc(500e18);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 500e18);
        assertEq(dsc.balanceOf(USER), 500e18);
    }

    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000e18);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 1000e18);
        assertEq(dsc.balanceOf(USER), 1000e18);
        assertEq(dsce.getCollateralBalanceOfUser(USER, weth), AMOUNT_COLLATERAL);
    }

    function testCanRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
        uint256 initialCollateral = dsce.getCollateralBalanceOfUser(USER, weth);
        uint256 initialDsc = dsc.balanceOf(USER);

        vm.startPrank(USER);
        dsc.approve(address(dsce), 500e18);
        dsce.redeemCollateralForDsc(weth, 2 ether, 500e18);
        vm.stopPrank();

        uint256 finalCollateral = dsce.getCollateralBalanceOfUser(USER, weth);
        uint256 finalDsc = dsc.balanceOf(USER);
        assertEq(finalCollateral, initialCollateral - 2 ether);
        assertEq(finalDsc, initialDsc - 500e18);
    }

    function testGetHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertGt(healthFactor, 1e18);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedValue);
    }

    /////////////////////////////////
    // Health Factor & Liquidation //
    /////////////////////////////////

    function testCanMintUpToMinHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MAX_DSC_FOR_COLLATERAL);
        vm.stopPrank();

        assertEq(dsce.getHealthFactor(USER), dsce.getMinHealthFactor());
    }

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
        uint256 amountToMint = MAX_DSC_FOR_COLLATERAL + 1;
        uint256 healthFactor = (MAX_DSC_FOR_COLLATERAL * 1e18) / amountToMint;

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCannotMintAgainstDustCollateral() public {
        // 1 wei of WETH is worth 2,000 wei of USD, so it backs at most 1,000 wei of DSC, not 1,000 DSC.
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 1);
        dsce.depositCollateral(weth, 1);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, uint256(1)));
        dsce.mintDsc(1000e18);
        vm.stopPrank();
    }

    function testCanLiquidateUndercollateralizedUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MAX_DSC_FOR_COLLATERAL);
        vm.stopPrank();

        // ETH drops from $2,000 to $1,800, so USER's health factor falls to 0.9.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ETH_USD_PRICE_AFTER_CRASH);
        assertLt(dsce.getHealthFactor(USER), dsce.getMinHealthFactor());

        uint256 liquidatorCollateral = 20 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, liquidatorCollateral);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), liquidatorCollateral);
        dsce.depositCollateralAndMintDsc(weth, liquidatorCollateral, MAX_DSC_FOR_COLLATERAL);
        dsc.approve(address(dsce), MAX_DSC_FOR_COLLATERAL);
        dsce.liquidate(weth, USER, MAX_DSC_FOR_COLLATERAL);
        vm.stopPrank();

        uint256 debtInWeth = dsce.getTokenAmountFromUsd(weth, MAX_DSC_FOR_COLLATERAL);
        uint256 bonus = (debtInWeth * dsce.getLiquidationBonus()) / dsce.getLiquidationPrecision();
        uint256 expectedPayout = debtInWeth + bonus;
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
        assertEq(ERC20Mock(weth).balanceOf(LIQUIDATOR), expectedPayout);
        assertEq(dsce.getCollateralBalanceOfUser(USER, weth), AMOUNT_COLLATERAL - expectedPayout);
    }

    function testRevertsIfLiquidatingUserAtMinHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MAX_DSC_FOR_COLLATERAL);
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOk.selector);
        dsce.liquidate(weth, USER, MAX_DSC_FOR_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfOraclePriceIsNotPositive() public {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);
        vm.expectRevert(OracleLib.OracleLib__InvalidPrice.selector);
        dsce.getUsdValue(weth, 1 ether);

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(-1);
        vm.expectRevert(OracleLib.OracleLib__InvalidPrice.selector);
        dsce.getTokenAmountFromUsd(weth, 1 ether);
    }

    function testGetters() public view {
        assertEq(dsce.getPrecision(), 1e18);
        assertEq(dsce.getAdditionalFeedPrecision(), 1e10);
        assertEq(dsce.getLiquidationThreshold(), 50);
        assertEq(dsce.getLiquidationBonus(), 10);
        assertEq(dsce.getMinHealthFactor(), 1e18);
        assertEq(dsce.getDsc(), address(dsc));
        assertEq(dsce.getCollateralTokenPriceFeed(weth), ethUsdPriceFeed);
    }
}
