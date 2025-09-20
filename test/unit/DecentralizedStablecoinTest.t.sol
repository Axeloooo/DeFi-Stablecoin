// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract DecentralizedStablecoinTest is Test {
    DeployDSC deployer;
    DecentralizedStablecoin dsc;
    DSCEngine dsce;
    HelperConfig config;

    address public USER = makeAddr("user");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
    }

    function testConstructorSetsNameAndSymbol() public view {
        assertEq(dsc.name(), "DecentralizedStablecoin");
        assertEq(dsc.symbol(), "DSC");
    }

    function testConstructorSetsInitialOwner() public view {
        assertEq(dsc.owner(), address(dsce));
    }

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(0x1e4fbdf7, address(0)));
        new DecentralizedStablecoin(address(0));
    }

    function testBurnSuccessful() public {
        uint256 balanceSlot = uint256(keccak256(abi.encode(address(dsce), uint256(0))));
        vm.store(address(dsc), bytes32(balanceSlot), bytes32(uint256(1000)));
        vm.store(address(dsc), bytes32(uint256(2)), bytes32(uint256(1000)));

        uint256 initialBalance = dsc.balanceOf(address(dsce));
        uint256 initialSupply = dsc.totalSupply();

        vm.prank(address(dsce));
        dsc.burn(500);

        assertEq(dsc.balanceOf(address(dsce)), initialBalance - 500);
        assertEq(dsc.totalSupply(), initialSupply - 500);
    }

    function testBurnRevertsIfNotOwner() public {
        vm.prank(USER);
        vm.expectRevert();
        dsc.burn(100);
    }

    function testBurnRevertsOnZeroAmount() public {
        vm.prank(address(dsce));
        vm.expectRevert(abi.encodeWithSignature("DecentralizedStablecoin__MustBeMoreThanZero()"));
        dsc.burn(0);
    }

    function testBurnRevertsOnInsufficientBalance() public {
        uint256 balanceSlot = uint256(keccak256(abi.encode(address(dsce), uint256(0))));
        vm.store(address(dsc), bytes32(balanceSlot), bytes32(uint256(100)));
        vm.store(address(dsc), bytes32(uint256(2)), bytes32(uint256(100)));

        vm.prank(address(dsce));
        vm.expectRevert(abi.encodeWithSignature("DecentralizedStablecoin__BurnAmountExceedsBalance()"));
        dsc.burn(200);
    }

    function testERC20Basics() public view {
        assertEq(dsc.name(), "DecentralizedStablecoin");
        assertEq(dsc.symbol(), "DSC");
        assertEq(dsc.decimals(), 18);
        assertEq(dsc.totalSupply(), 0);
        assertEq(dsc.balanceOf(address(this)), 0);
    }
}
