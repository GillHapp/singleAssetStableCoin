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
    uint256 public constant INITIAL_ETH_PRICE = 2500e8; // $2500 per ETH, 8 decimals
    address public user = address(0x123);
    address public liquidator = address(0x456);
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant INITIAL_COLLATERAL = 2 ether; // 2 ETH = $5000
    uint256 public constant INITIAL_SSC_MINTED = 1000e18; // 1000 SSC = $1000
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    // Events for testing
    event CollateralDeposited(address indexed user, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, uint256 amount);
    event SSCMinted(address indexed user, uint256 indexed amount);
    event SSCBurned(address indexed user, uint256 indexed amount);

    function setUp() public {
        // Deploy mock price feed with ETH price = $2500
        priceFeed = new MockV3Aggregator(8, int256(INITIAL_ETH_PRICE));
        // Deploy contract
        ssc = new SingleAssetStableCoin(address(priceFeed));
        // Fund user and liquidator with ETH
        vm.deal(user, STARTING_USER_BALANCE);
        vm.deal(liquidator, STARTING_USER_BALANCE);
        // Mint SSC to liquidator for liquidation tests
        vm.prank(address(this));
        ssc.mint(liquidator, INITIAL_SSC_MINTED);
        // Approve SSC for liquidator
        vm.prank(liquidator);
        ssc.approve(address(ssc), type(uint256).max);
    }

    // ------------------ Constructor Tests ------------------
    function test_ContractInstantiation() public view {
        assertTrue(address(ssc) != address(0), "Contract should be deployed");
        assertEq(ssc.name(), "SingleAssetStableCoin", "Token name should be SingleAssetStableCoin");
        assertEq(ssc.symbol(), "SSC", "Token symbol should be SSC");
        assertEq(ssc.decimals(), 18, "Token decimals should be 18");
        assertEq(ssc.owner(), address(this), "Owner should be test contract");
        assertEq(ssc.getEthPriceFeed(), address(priceFeed), "Price feed address should match");
    }

    // ------------------ Price Tests ------------------
    function test_GetUsdValue() public view {
        uint256 ethAmount = 2e18; // 2 ETH
        uint256 expectedUsd = 5000e18; // 2 * $2500 * 1e18
        uint256 usdValue = ssc.getUsdValue(ethAmount);
        assertEq(usdValue, expectedUsd, "USD value should be $5000");
    }

    function test_GetTokenAmountFromUsd() public view {
        uint256 usdAmount = 5000e18; // $5000
        uint256 expectedEth = 2e18; // $5000 / $2500 = 2 ETH
        uint256 ethAmount = ssc.getTokenAmountFromUsd(usdAmount);
        assertEq(ethAmount, expectedEth, "ETH amount should be 2 ETH");
    }

    function test_RevertWhen_GetTokenAmountFromUsd_ZeroPrice() public {
        vm.prank(address(this));
        priceFeed.updateAnswer(0);
        vm.expectRevert(SingleAssetStableCoin.AmountMustBeMoreThanZero.selector);
        ssc.getTokenAmountFromUsd(1000e18);
    }

    // ------------------ DepositCollateralAndMintSsc Tests ------------------
    function test_DepositCollateralAndMintSsc_Success() public {
        vm.startPrank(user);
        vm.deal(user, STARTING_USER_BALANCE); // Ensure user has enough ETH
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(INITIAL_SSC_MINTED);
        vm.stopPrank();

        uint256 collateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(collateralBalance, INITIAL_COLLATERAL, "Collateral balance should be 2 ETH");

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, INITIAL_SSC_MINTED, "SSC minted should be 1000 SSC");
        assertEq(collateralValueInUsd, 5000e18, "Collateral value should be $5000");

        uint256 userSscBalance = ssc.balanceOf(user);
        assertEq(userSscBalance, INITIAL_SSC_MINTED, "User SSC balance should be 1000 SSC");

        uint256 expectedHealthFactor =
            (5000e18 * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * 1e18) / INITIAL_SSC_MINTED; // 2.5e18
        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 2.5");
    }

    function test_RevertWhen_DepositCollateralAndMintSsc_ZeroCollateral() public {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
        ssc.depositCollateralAndMintSsc{value: 0}(INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositCollateralAndMintSsc_ZeroSsc() public {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositCollateralAndMintSsc_BreaksHealthFactor() public {
        // Max SSC = 5000e18 * 0.5 = 2500e18
        uint256 excessiveSsc = 3000e18; // Would result in health factor = (5000e18 * 0.5) / 3000e18 = 0.833e18 < 1e18
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetStableCoin.BreaksHealthFactor.selector, 833333333333333333));
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(excessiveSsc);
        vm.stopPrank();
    }

    function test_DepositCollateralAndMintSsc_EmitsEvents() public {
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true, address(ssc));
        emit CollateralDeposited(user, INITIAL_COLLATERAL);
        vm.expectEmit(true, true, false, true, address(ssc));
        emit SSCMinted(user, INITIAL_SSC_MINTED);
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    // ------------------ RedeemCollateralForSsc Tests ------------------
    modifier depositedCollateralAndMintedSsc() {
        vm.startPrank(user);
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(INITIAL_SSC_MINTED);
        ssc.approve(address(ssc), INITIAL_SSC_MINTED);
        vm.stopPrank();
        _;
    }

    function test_RedeemCollateralForSsc_Success() public depositedCollateralAndMintedSsc {
        uint256 initialUserEthBalance = user.balance;
        vm.startPrank(user);
        ssc.redeemCollateralForSsc(INITIAL_COLLATERAL, INITIAL_SSC_MINTED);
        vm.stopPrank();

        uint256 finalCollateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(finalCollateralBalance, 0, "Collateral balance should be 0");

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, 0, "SSC minted should be 0");
        assertEq(collateralValueInUsd, 0, "Collateral value should be $0");

        uint256 userSscBalance = ssc.balanceOf(user);
        assertEq(userSscBalance, 0, "User SSC balance should be 0");

        uint256 finalUserEthBalance = user.balance;
        assertEq(finalUserEthBalance, initialUserEthBalance + INITIAL_COLLATERAL, "User should receive 2 ETH back");

        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max");
    }

    function test_RedeemCollateralForSsc_PartialSuccess() public depositedCollateralAndMintedSsc {
        uint256 partialCollateral = 1e18; // 1 ETH
        uint256 partialSsc = 500e18; // 500 SSC
        uint256 initialUserEthBalance = user.balance;
        vm.startPrank(user);
        ssc.redeemCollateralForSsc(partialCollateral, partialSsc);
        vm.stopPrank();

        uint256 finalCollateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(finalCollateralBalance, INITIAL_COLLATERAL - partialCollateral, "Collateral balance should be 1 ETH");

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, INITIAL_SSC_MINTED - partialSsc, "SSC minted should be 500 SSC");
        assertEq(collateralValueInUsd, 2500e18, "Collateral value should be $2500");

        uint256 userSscBalance = ssc.balanceOf(user);
        assertEq(userSscBalance, INITIAL_SSC_MINTED - partialSsc, "User SSC balance should be 500 SSC");

        uint256 finalUserEthBalance = user.balance;
        assertEq(finalUserEthBalance, initialUserEthBalance + partialCollateral, "User should receive 1 ETH back");

        uint256 expectedHealthFactor =
            (2500e18 * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * 1e18) / (INITIAL_SSC_MINTED - partialSsc); // (2500e18 * 0.5) / 500e18 = 2.5e18
        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 2.5");
    }

    function test_RevertWhen_RedeemCollateralForSsc_ZeroCollateral() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
        ssc.redeemCollateralForSsc(0, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemCollateralForSsc_ZeroSsc() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
        ssc.redeemCollateralForSsc(INITIAL_COLLATERAL, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemCollateralForSsc_InsufficientCollateral() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.AmountMustBeMoreThanZero.selector);
        ssc.redeemCollateralForSsc(INITIAL_COLLATERAL + 1e18, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemCollateralForSsc_InsufficientSsc() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.AmountMustBeMoreThanZero.selector);
        ssc.redeemCollateralForSsc(INITIAL_COLLATERAL, INITIAL_SSC_MINTED + 1e18);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemCollateralForSsc_BreaksHealthFactor() public depositedCollateralAndMintedSsc {
        // Redeem 1.5 ETH ($3750), keep 500 SSC: health factor = (1250e18 * 0.5) / 500e18 = 1.25e18 (safe)
        // Redeem 1.6 ETH ($4000), keep 500 SSC: health factor = (1000e18 * 0.5) / 500e18 = 1e18 (safe)
        // Redeem 1.7 ETH ($4250), keep 500 SSC: health factor = (750e18 * 0.5) / 500e18 = 0.75e18 (unsafe)
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetStableCoin.BreaksHealthFactor.selector, 750000000000000000));
        ssc.redeemCollateralForSsc(1.7 ether, 500e18);
        vm.stopPrank();
    }

    function test_RedeemCollateralForSsc_EmitsEvents() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.deal(user, 10 ether); // Ensure user has enough ETH
        vm.expectEmit(true, true, false, true, address(ssc));
        emit SSCBurned(user, INITIAL_SSC_MINTED);
        vm.expectEmit(true, true, false, true, address(ssc));
        emit CollateralRedeemed(user, user, INITIAL_COLLATERAL);
        ssc.redeemCollateralForSsc(INITIAL_COLLATERAL, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    // ------------------ RedeemCollateral Tests ------------------
    function test_RedeemCollateral_Success() public depositedCollateralAndMintedSsc {
        uint256 initialUserEthBalance = user.balance;
        vm.startPrank(user);
        ssc.redeemCollateral(0.5 ether); // Redeem 0.5 ETH, health factor = (3750e18 * 0.5) / 1000e18 = 1.875e18
        vm.stopPrank();

        uint256 finalCollateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(finalCollateralBalance, INITIAL_COLLATERAL - 0.5 ether, "Collateral balance should be 1.5 ETH");

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, INITIAL_SSC_MINTED, "SSC minted should be unchanged");
        assertEq(collateralValueInUsd, 3750e18, "Collateral value should be $3750");

        uint256 finalUserEthBalance = user.balance;
        assertEq(finalUserEthBalance, initialUserEthBalance + 0.5 ether, "User should receive 0.5 ETH back");

        uint256 expectedHealthFactor =
            (3750e18 * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * 1e18) / INITIAL_SSC_MINTED; // 1.875e18
        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 1.875");
    }

    function test_RevertWhen_RedeemCollateral_Zero() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
        ssc.redeemCollateral(0);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemCollateral_InsufficientCollateral() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.AmountMustBeMoreThanZero.selector);
        ssc.redeemCollateral(INITIAL_COLLATERAL + 1e18);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemCollateral_BreaksHealthFactor() public depositedCollateralAndMintedSsc {
        // Redeem 1.5 ETH ($3750): health factor = (1250e18 * 0.5) / 1000e18 = 0.625e18 < 1e18
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetStableCoin.BreaksHealthFactor.selector, 625000000000000000));
        ssc.redeemCollateral(1.5 ether);
        vm.stopPrank();
    }

    // ------------------ BurnSsc Tests ------------------
    function test_BurnSsc_Success() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        ssc.burnSsc(500e18); // Burn 500 SSC
        vm.stopPrank();

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, INITIAL_SSC_MINTED - 500e18, "SSC minted should be 500 SSC");
        assertEq(collateralValueInUsd, 5000e18, "Collateral value should be $5000");

        uint256 userSscBalance = ssc.balanceOf(user);
        assertEq(userSscBalance, INITIAL_SSC_MINTED - 500e18, "User SSC balance should be 500 SSC");

        uint256 expectedHealthFactor =
            (5000e18 * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * 1e18) / (INITIAL_SSC_MINTED - 500e18); // 5e18
        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 5");
    }

    function test_RevertWhen_BurnSsc_Zero() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
        ssc.burnSsc(0);
        vm.stopPrank();
    }

    function test_RevertWhen_BurnSsc_InsufficientSsc() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectRevert(SingleAssetStableCoin.AmountMustBeMoreThanZero.selector);
        ssc.burnSsc(INITIAL_SSC_MINTED + 1e18);
        vm.stopPrank();
    }

    function test_BurnSsc_EmitsEvent() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true, address(ssc));
        emit SSCBurned(user, 500e18);
        ssc.burnSsc(500e18);
        vm.stopPrank();
    }

    // ------------------ Mint Tests ------------------
    function test_Mint_Success() public {
        vm.startPrank(address(this));
        bool success = ssc.mint(user, INITIAL_SSC_MINTED);
        vm.stopPrank();

        assertTrue(success, "Mint should succeed");
        uint256 userSscBalance = ssc.balanceOf(user);
        assertEq(userSscBalance, INITIAL_SSC_MINTED, "User SSC balance should be 1000 SSC");
    }

    function test_RevertWhen_Mint_ZeroAmount() public {
        vm.startPrank(address(this));
        vm.expectRevert(SingleAssetStableCoin.AmountMustBeMoreThanZero.selector);
        ssc.mint(user, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_Mint_ZeroAddress() public {
        vm.startPrank(address(this));
        vm.expectRevert(SingleAssetStableCoin.NotZeroAddress.selector);
        ssc.mint(address(0), INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    function test_Mint_EmitsEvent() public {
        vm.startPrank(address(this));
        vm.expectEmit(true, true, false, true, address(ssc));
        emit SSCMinted(user, INITIAL_SSC_MINTED);
        ssc.mint(user, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    // ------------------ Liquidation Tests ------------------
    modifier liquidated() {
        vm.startPrank(user);
        ssc.depositCollateralAndMintSsc{value: INITIAL_COLLATERAL}(INITIAL_SSC_MINTED);
        ssc.approve(address(ssc), INITIAL_SSC_MINTED);
        vm.stopPrank();
        priceFeed.updateAnswer(1000e8); // ETH price = $1000, health factor = (2000e18 * 0.5) / 1000e18 = 1e18
        vm.startPrank(liquidator);
        ssc.liquidate(user, INITIAL_SSC_MINTED);
        vm.stopPrank();
        _;
    }

    function test_Liquidate_Success() public depositedCollateralAndMintedSsc {
        priceFeed.updateAnswer(83333333333); // ETH price ≈ $833.33, health factor ≈ 0.83333e18
        vm.startPrank(liquidator);
        uint256 initialLiquidatorEthBalance = liquidator.balance;
        ssc.liquidate(user, INITIAL_SSC_MINTED);
        vm.stopPrank();

        uint256 collateralRedeemed = ssc.getTokenAmountFromUsd(INITIAL_SSC_MINTED); // 1000e18 / ($833.33 * 1e10) ≈ 1.2e18 ETH
        uint256 bonusCollateral = (collateralRedeemed * 10) / 100; // 10% bonus ≈ 0.12e18 ETH
        uint256 totalCollateralRedeemed = collateralRedeemed + bonusCollateral; // ≈ 1.32e18 ETH

        uint256 finalCollateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(
            finalCollateralBalance,
            INITIAL_COLLATERAL - totalCollateralRedeemed,
            "Collateral balance should be ~0.68 ETH"
        );

        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, 0, "SSC minted should be 0");
        assertEq(collateralValueInUsd, 566666666660000000000, "Collateral value should be ~$566.6666"); // Precise value

        uint256 liquidatorEthBalance = liquidator.balance;
        assertEq(
            liquidatorEthBalance,
            initialLiquidatorEthBalance + totalCollateralRedeemed,
            "Liquidator should receive ~1.32 ETH"
        );

        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max");
    }

    function test_RevertWhen_Liquidate_HealthFactorOk() public depositedCollateralAndMintedSsc {
        // Health factor = (5000e18 * 0.5) / 1000e18 = 2.5e18 (safe)
        vm.startPrank(liquidator);
        vm.expectRevert(SingleAssetStableCoin.HealthFactorOk.selector);
        ssc.liquidate(user, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    function test_RevertWhen_Liquidate_ZeroDebt() public depositedCollateralAndMintedSsc {
        vm.startPrank(user);
        ssc.burnSsc(INITIAL_SSC_MINTED); // Burn all SSC
        vm.stopPrank();
        priceFeed.updateAnswer(1000e8); // ETH price = $1000
        vm.startPrank(liquidator);
        vm.expectRevert(SingleAssetStableCoin.HealthFactorOk.selector);
        ssc.liquidate(user, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    function test_Liquidate_EmitsEvents() public depositedCollateralAndMintedSsc {
        priceFeed.updateAnswer(83333333333); // ETH price ≈ $833.33, health factor ≈ 0.83333e18
        uint256 collateralRedeemed = ssc.getTokenAmountFromUsd(INITIAL_SSC_MINTED); // 1.2e18 ETH
        uint256 bonusCollateral = (collateralRedeemed * 10) / 100; // 0.12e18 ETH
        vm.startPrank(liquidator);
        vm.expectEmit(true, true, false, true, address(ssc));
        emit CollateralRedeemed(user, liquidator, collateralRedeemed + bonusCollateral);
        vm.expectEmit(true, true, false, true, address(ssc));
        emit SSCBurned(user, INITIAL_SSC_MINTED);
        ssc.liquidate(user, INITIAL_SSC_MINTED);
        vm.stopPrank();
    }

    // ------------------ View & Pure Function Tests ------------------
    function test_GetAccountInformation() public depositedCollateralAndMintedSsc {
        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertEq(totalSscMinted, INITIAL_SSC_MINTED, "SSC minted should be 1000 SSC");
        assertEq(collateralValueInUsd, 5000e18, "Collateral value should be $5000");
    }

    function test_GetCollateralBalanceOfUser() public depositedCollateralAndMintedSsc {
        uint256 collateralBalance = ssc.getCollateralBalanceOfUser(user);
        assertEq(collateralBalance, INITIAL_COLLATERAL, "Collateral balance should be 2 ETH");
    }

    function test_GetAccountCollateralValue() public depositedCollateralAndMintedSsc {
        uint256 collateralValue = ssc.getAccountCollateralValue(user);
        assertEq(collateralValue, 5000e18, "Collateral value should be $5000");
    }

    function test_GetHealthFactor() public depositedCollateralAndMintedSsc {
        uint256 healthFactor = ssc.getHealthFactor(user);
        uint256 expectedHealthFactor =
            (5000e18 * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * 1e18) / INITIAL_SSC_MINTED; // 2.5e18
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 2.5");
    }

    function test_GetHealthFactor_ZeroSsc() public view {
        uint256 healthFactor = ssc.getHealthFactor(user);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max with no SSC");
    }

    function test_CalculateHealthFactor() public view {
        uint256 healthFactor = ssc.calculateHealthFactor(1000e18, 5000e18);
        uint256 expectedHealthFactor = (5000e18 * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * 1e18) / 1000e18; // 2.5e18
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be 2.5");
    }

    function test_GetLiquidationThreshold() public view {
        uint256 threshold = ssc.getLiquidationThreshold();
        assertEq(threshold, LIQUIDATION_THRESHOLD, "Liquidation threshold should be 50");
    }

    function test_GetLiquidationBonus() public view {
        uint256 bonus = ssc.getLiquidationBonus();
        assertEq(bonus, 10, "Liquidation bonus should be 10");
    }

    function test_GetLiquidationPrecision() public view {
        uint256 precision = ssc.getLiquidationPrecision();
        assertEq(precision, LIQUIDATION_PRECISION, "Liquidation precision should be 100");
    }

    function test_GetMinHealthFactor() public view {
        uint256 minHealthFactor = ssc.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR, "Min health factor should be 1e18");
    }

    function test_GetPrecision() public view {
        uint256 precision = ssc.getPrecision();
        assertEq(precision, 1e18, "Precision should be 1e18");
    }

    function test_GetAdditionalFeedPrecision() public view {
        uint256 feedPrecision = ssc.getAdditionalFeedPrecision();
        assertEq(feedPrecision, 1e10, "Additional feed precision should be 1e10");
    }

    // ------------------ Invariant Test ------------------
    function test_Invariant_CollateralValueGteSscMinted() public depositedCollateralAndMintedSsc {
        (uint256 totalSscMinted, uint256 collateralValueInUsd) = ssc.getAccountInformation(user);
        assertGe(
            collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION,
            totalSscMinted,
            "Collateral value must cover SSC minted"
        );
    }
}
