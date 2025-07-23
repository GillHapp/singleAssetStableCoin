// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SingleAssetStableCoin} from "../src/SingleAssetStableCoin.sol";
import {MockV3Aggregator} from
    "../lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract SingleAssetStableCoinTest is Test {
    SingleAssetStableCoin public ssc;
    MockV3Aggregator public priceFeed;
    address public constant ETH_USD_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    uint256 public constant INITIAL_ETH_PRICE = 2500e8; // $2500 per ETH, 8 decimals for MockV3Aggregator
    address public user = address(0x123);
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant INITIAL_COLLATERAL = 2 ether; // 2 ETH
    uint256 public constant INITIAL_SSC_MINTED = 1000e18; // 1000 SSC ($1000)

    function setUp() public {
        // Deploy mock price feed with initial ETH price of $2500
        priceFeed = new MockV3Aggregator(8, int256(INITIAL_ETH_PRICE));
        // Instantiate the SingleAssetStableCoin contract
        ssc = new SingleAssetStableCoin(address(priceFeed));
    }

    function test_ContractInstantiation() public view {
        // Verify contract is deployed
        assertTrue(address(ssc) != address(0), "Contract should be deployed");

        // Verify token details
        assertEq(ssc.name(), "SingleAssetStableCoin", "Token name should be SingleAssetStableCoin");
        assertEq(ssc.symbol(), "SSC", "Token symbol should be SSC");
        assertEq(ssc.decimals(), 18, "Token decimals should be 18");

        // Verify owner
        assertEq(ssc.owner(), address(this), "Owner should be the test contract");

        // Verify price feed address
        assertEq(ssc.getEthPriceFeed(), address(priceFeed), "Price feed address should match");
    }

    function test_DepositCollateralAndMintSsc_Success() public {
        // Arrange
        vm.startPrank(user);
        vm.deal(user, 10 ether); // Give user some ETH
        // Act
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(INITIAL_SSC_MINTED);
        vm.stopPrank();

        // Assert
        uint256 collateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(collateralBalance, INITIAL_COLLATERAL, "Collateral balance should be 2 ETH");

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, INITIAL_SSC_MINTED, "SSC minted should be 1000 SSC");
        assertEq(collateralValueInUsd, 5000e18, "Collateral value should be $5000");

        uint256 userSscBalance = ssc.balanceOf(user);
        assertEq(userSscBalance, INITIAL_SSC_MINTED, "User SSC balance should be 1000 SSC");

        uint256 expectedHealthFactor = (5000e18 * 50 / 100 * 1e18) / INITIAL_SSC_MINTED; // (5000e18 * 0.5) / 2000e18 = 1.25e18
        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 1.25");
    }
}
