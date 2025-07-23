// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.29;

// import {Test, console} from "forge-std/Test.sol";
// import {StdCheats} from "forge-std/StdCheats.sol";
// import {SingleAssetStableCoin} from "../src/SingleAssetStableCoin.sol";
// import {MockV3Aggregator} from
//     "../lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";
// import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// contract SingleAssetStableCoinTest is Test {
//     // Constants
//     uint256 private constant WETH_PRICE = 2000e8; // $2000 per WETH, 8 decimals
//     uint256 private constant PRECISION = 1e18;
//     uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
//     uint256 private constant LIQUIDATION_THRESHOLD = 50;
//     uint256 private constant LIQUIDATION_PRECISION = 100;
//     uint256 private constant MIN_HEALTH_FACTOR = 1e18;
//     uint256 private constant LIQUIDATION_BONUS = 10;

//     // Test contracts and addresses
//     SingleAssetStableCoin private ssc;
//     address private weth = 0x59cD1C87501baa753d0B5B5Ab5D8416A45cD71DB;
//     address private priceFeed = 0xc59E3633BAAC79493d908e63626716e204A45EdF;
//     address private user = address(0x1);
//     address private liquidator = address(0x2);

//     // Ghost variables for invariant testing
//     uint256 private totalSscMinted;
//     uint256 private totalCollateralDeposited;

//     // Actors for invariant testing
//     address[] private actors;

//     function setUp() external {
//         // Deploy mock WETH

//         // Deploy mock Chainlink price feed (8 decimals)

//         // Deploy SingleAssetStableCoin
//         ssc = new SingleAssetStableCoin(address(weth), address(priceFeed));

//         // Setup actors
//         actors.push(user);
//         actors.push(liquidator);
//         vm.label(user, "User");
//         vm.label(liquidator, "Liquidator");

//         // Fund users with WETH and SSC
//         vm.deal(user, 100 ether);
//         vm.deal(liquidator, 100 ether);
//         deal(address(weth), user, 100e18);
//         deal(address(weth), liquidator, 100e18);
//     }

//     // ------------------ UNIT TESTS ------------------

//     /// @notice Tests constructor initialization
//     function test_Constructor_SetsCorrectAddresses() public {
//         assertEq(ssc.getWethAddress(), address(weth), "WETH address not set correctly");
//         assertEq(ssc.getWethPriceFeed(), address(priceFeed), "Price feed address not set correctly");
//         assertEq(ssc.owner(), address(this), "Owner not set correctly");
//     }

//     /// @notice Tests depositCollateral with valid inputs
//     function test_DepositCollateral_Success() public {
//         uint256 amount = 1e18; // 1 WETH
//         vm.startPrank(user);
//         weth.approve(address(ssc), amount);

//         vm.expectEmit(true, false, false, true);
//         emit SingleAssetStableCoin.CollateralDeposited(user, amount);
//         ssc.depositCollateral(address(weth), amount);

//         assertEq(ssc.getCollateralBalanceOfUser(user), amount, "Collateral balance incorrect");
//         assertEq(weth.balanceOf(address(ssc)), amount, "WETH not transferred to contract");
//         assertEq(weth.balanceOf(user), 99e18, "User WETH balance not reduced");
//         vm.stopPrank();
//     }

//     /// @notice Tests depositCollateral reverts with zero amount
//     function test_RevertWhen_DepositCollateral_ZeroAmount() public {
//         vm.startPrank(user);
//         vm.expectRevert(SingleAssetStableCoin.NeedsMoreThanZero.selector);
//         ssc.depositCollateral(address(weth), 0);
//         vm.stopPrank();
//     }

//     /// @notice Tests depositCollateral reverts with invalid token
//     function test_RevertWhen_DepositCollateral_InvalidToken() public {
//         address invalidToken = address(0x3);
//         vm.startPrank(user);
//         vm.expectRevert(SingleAssetStableCoin.InvalidCollateralToken.selector);
//         ssc.depositCollateral(invalidToken, 1e18);
//         vm.stopPrank();
//     }

//     /// @notice Tests mintSsc with sufficient collateral
//     function test_MintSsc_Success() public {
//         uint256 collateralAmount = 2e18; // 2 WETH = $4000
//         uint256 sscAmount = 1000e18; // 1000 SSC = $1000
//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);

//         vm.expectEmit(true, false, false, true);
//         emit SingleAssetStableCoin.SSCMinted(user, sscAmount);
//         ssc.mintSsc(sscAmount);

//         assertEq(ssc.balanceOf(user), sscAmount, "SSC balance incorrect");
//         assertEq(ssc.sscMinted(user), sscAmount, "Minted SSC tracking incorrect");
//         assertGe(ssc.getHealthFactor(user), MIN_HEALTH_FACTOR, "Health factor below minimum");
//         vm.stopPrank();
//     }

//     /// @notice Tests mintSsc reverts if health factor breaks
//     function test_RevertWhen_MintSsc_BreaksHealthFactor() public {
//         uint256 collateralAmount = 1e18; // 1 WETH = $2000
//         uint256 sscAmount = 1001e18; // 1001 SSC > $1000 (health factor < 1)
//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);

//         vm.expectRevert(abi.encodeWithSelector(SingleAssetStableCoin.BreaksHealthFactor.selector, 0.999e18));
//         ssc.mintSsc(sscAmount);
//         vm.stopPrank();
//     }

//     /// @notice Tests redeemCollateral with valid inputs
//     function test_RedeemCollateral_Success() public {
//         uint256 collateralAmount = 2e18; // 2 WETH
//         uint256 redeemAmount = 1e18; // 1 WETH
//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);

//         vm.expectEmit(true, true, false, true);
//         emit SingleAssetStableCoin.CollateralRedeemed(user, user, redeemAmount);
//         ssc.redeemCollateral(address(weth), redeemAmount);

//         assertEq(ssc.getCollateralBalanceOfUser(user), collateralAmount - redeemAmount, "Collateral balance incorrect");
//         assertEq(weth.balanceOf(user), 99e18, "WETH not returned to user");
//         vm.stopPrank();
//     }

//     /// @notice Tests redeemCollateral reverts if health factor breaks
//     function test_RevertWhen_RedeemCollateral_BreaksHealthFactor() public {
//         uint256 collateralAmount = 2e18; // 2 WETH = $4000
//         uint256 sscAmount = 1000e18; // 1000 SSC
//         uint256 redeemAmount = 1.5e18; // 1.5 WETH, leaving 0.5 WETH ($1000, health factor < 1)
//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);
//         ssc.mintSsc(sscAmount);

//         vm.expectRevert(abi.encodeWithSelector(SingleAssetStableCoin.BreaksHealthFactor.selector, 0.5e18));
//         ssc.redeemCollateral(address(weth), redeemAmount);
//         vm.stopPrank();
//     }

//     /// @notice Tests burnSsc with valid inputs
//     function test_BurnSsc_Success() public {
//         uint256 collateralAmount = 2e18; // 2 WETH
//         uint256 sscAmount = 1000e18; // 1000 SSC
//         uint256 burnAmount = 500e18; // 500 SSC
//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);
//         ssc.mintSsc(sscAmount);
//         ssc.approve(address(ssc), burnAmount);

//         vm.expectEmit(true, false, false, true);
//         emit SingleAssetStableCoin.SSCBurned(user, burnAmount);
//         ssc.burnSsc(burnAmount);

//         assertEq(ssc.balanceOf(user), sscAmount - burnAmount, "SSC balance incorrect");
//         assertEq(ssc.sscMinted(user), sscAmount - burnAmount, "Minted SSC tracking incorrect");
//         assertGe(ssc.getHealthFactor(user), MIN_HEALTH_FACTOR, "Health factor below minimum");
//         vm.stopPrank();
//     }

//     /// @notice Tests liquidate with valid inputs
//     function test_Liquidate_Success() public {
//         // Setup: User deposits 1 WETH ($2000), mints 1000 SSC ($1000, health factor = 1)
//         vm.startPrank(user);
//         weth.approve(address(ssc), 1e18);
//         ssc.depositCollateral(address(weth), 1e18);
//         ssc.mintSsc(1000e18);
//         vm.stopPrank();

//         // Simulate price drop to $1500 (health factor = 0.75)
//         priceFeed.updateAnswer(int256(1500e8));

//         // Liquidator covers 500 SSC debt
//         uint256 debtToCover = 500e18; // $500
//         uint256 tokenAmount = ssc.getTokenAmountFromUsd(debtToCover); // $500 / $1500 = ~0.333e18 WETH
//         uint256 bonus = (tokenAmount * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // 10% bonus
//         uint256 totalCollateral = tokenAmount + bonus;

//         vm.startPrank(liquidator);
//         deal(address(ssc), liquidator, debtToCover);
//         ssc.approve(address(ssc), debtToCover);

//         vm.expectEmit(true, true, false, true);
//         emit SingleAssetStableCoin.CollateralRedeemed(user, liquidator, totalCollateral);
//         vm.expectEmit(true, false, false, true);
//         emit SingleAssetStableCoin.SSCBurned(user, debtToCover);
//         ssc.liquidate(address(weth), user, debtToCover);

//         assertEq(ssc.sscMinted(user), 500e18, "SSC debt not reduced correctly");
//         assertEq(ssc.getCollateralBalanceOfUser(user), 1e18 - totalCollateral, "Collateral not reduced correctly");
//         assertEq(weth.balanceOf(liquidator), 100e18 + totalCollateral, "Liquidator WETH balance incorrect");
//         assertGe(ssc.getHealthFactor(user), MIN_HEALTH_FACTOR, "User health factor not improved");
//         vm.stopPrank();
//     }

//     /// @notice Tests liquidate reverts if health factor is okay
//     function test_RevertWhen_Liquidate_HealthFactorOk() public {
//         vm.startPrank(user);
//         weth.approve(address(ssc), 2e18);
//         ssc.depositCollateral(address(weth), 2e18); // 2 WETH = $4000
//         ssc.mintSsc(1000e18); // 1000 SSC, health factor = 2
//         vm.stopPrank();

//         vm.startPrank(liquidator);
//         deal(address(ssc), liquidator, 500e18);
//         ssc.approve(address(ssc), 500e18);
//         vm.expectRevert(SingleAssetStableCoin.HealthFactorOk.selector);
//         ssc.liquidate(address(weth), user, 500e18);
//         vm.stopPrank();
//     }

//     /// @notice Tests getUsdValue and getTokenAmountFromUsd
//     function test_GetUsdValue_And_GetTokenAmountFromUsd() public {
//         uint256 amount = 1e18; // 1 WETH
//         uint256 usdValue = ssc.getUsdValue(amount); // 1 WETH * $2000 = $2000
//         assertEq(usdValue, 2000e18, "USD value incorrect");

//         uint256 tokenAmount = ssc.getTokenAmountFromUsd(2000e18); // $2000 / $2000 = 1 WETH
//         assertEq(tokenAmount, 1e18, "Token amount incorrect");
//     }

//     // ------------------ FUZZ TESTS ------------------

//     /// @notice Fuzz test for depositCollateral
//     function testFuzz_DepositCollateral(uint96 amount) public {
//         amount = uint96(bound(amount, 1, 100e18));
//         vm.startPrank(user);
//         weth.approve(address(ssc), amount);
//         ssc.depositCollateral(address(weth), amount);
//         assertEq(ssc.getCollateralBalanceOfUser(user), amount, "Collateral balance incorrect");
//         vm.stopPrank();
//     }

//     /// @notice Fuzz test for mintSsc with valid health factor
//     function testFuzz_MintSsc(uint96 collateralAmount, uint96 sscAmount) public {
//         collateralAmount = uint96(bound(collateralAmount, 1e18, 100e18)); // 1-100 WETH
//         uint256 maxSsc = (ssc.getUsdValue(collateralAmount) * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // Max SSC for health factor >= 1
//         sscAmount = uint96(bound(sscAmount, 1, maxSsc));

//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);
//         ssc.mintSsc(sscAmount);
//         assertEq(ssc.balanceOf(user), sscAmount, "SSC balance incorrect");
//         assertGe(ssc.getHealthFactor(user), MIN_HEALTH_FACTOR, "Health factor below minimum");
//         vm.stopPrank();
//     }

//     /// @notice Fuzz test for liquidate
//     function testFuzz_Liquidate(uint96 collateralAmount, uint96 debtToCover) public {
//         collateralAmount = uint96(bound(collateralAmount, 1e18, 10e18)); // 1-10 WETH
//         vm.startPrank(user);
//         weth.approve(address(ssc), collateralAmount);
//         ssc.depositCollateral(address(weth), collateralAmount);
//         uint256 maxSsc = (ssc.getUsdValue(collateralAmount) * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
//         ssc.mintSsc(maxSsc);
//         vm.stopPrank();

//         // Simulate price drop to make health factor < 1
//         priceFeed.updateAnswer(int256(1000e8)); // WETH = $1000
//         debtToCover = uint96(bound(debtToCover, 1, maxSsc));

//         vm.startPrank(liquidator);
//         deal(address(ssc), liquidator, debtToCover);
//         ssc.approve(address(ssc), debtToCover);
//         ssc.liquidate(address(weth), user, debtToCover);
//         assertGe(ssc.getHealthFactor(user), MIN_HEALTH_FACTOR, "Health factor not improved");
//         vm.stopPrank();
//     }

//     // ------------------ INVARIANT TESTS ------------------

//     /// @notice Invariant: Total SSC minted <= Collateral value / 2
//     function invariant_SscMintedLessThanCollateralValue() public {
//         uint256 totalCollateralValue = ssc.getAccountCollateralValue(user);
//         uint256 maxSsc = (totalCollateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
//         assertLe(ssc.sscMinted(user), maxSsc, "SSC minted exceeds collateral value");
//     }

//     /// @notice Sets up invariant tests with handler
//     function test_Invariant_Setup() public {
//         Handler handler = new Handler(ssc, weth, user, liquidator);
//         targetContract(address(handler));
//         targetSender(user);
//         targetSender(liquidator);
//     }
// }

// /// @notice Handler for invariant testing
// contract Handler is Test {
//     SingleAssetStableCoin private ssc;
//     IERC20 private weth;
//     address private user;
//     address private liquidator;

//     constructor(SingleAssetStableCoin _ssc, IERC20 _weth, address _user, address _liquidator) {
//         ssc = _ssc;
//         weth = _weth;
//         user = _user;
//         liquidator = _liquidator;
//     }

//     function depositCollateral(uint96 amount) external {
//         amount = uint96(bound(amount, 1e16, 100e18));
//         vm.startPrank(user);
//         deal(address(weth), user, amount);
//         weth.approve(address(ssc), amount);
//         ssc.depositCollateral(address(weth), amount);
//         vm.stopPrank();
//     }

//     function mintSsc(uint96 amount) external {
//         uint256 maxSsc = (ssc.getAccountCollateralValue(user));
//         amount = uint96(bound(amount, 1, maxSsc));
//         vm.startPrank(user);
//         ssc.mintSsc(amount);
//         vm.stopPrank();
//     }

//     function liquidate(uint96 debtToCover) external {
//         uint256 maxSsc = ssc.sscMinted(user);
//         debtToCover = uint96(bound(debtToCover, 1, maxSsc));
//         vm.startPrank(user);
//         weth.approve(address(ssc), 1e18);
//         ssc.depositCollateral(address(weth), 1e18);
//         ssc.mintSsc(maxSsc);
//         vm.stopPrank();

//         // Simulate price drop
//         MockV3Aggregator priceFeed = MockV3Aggregator(ssc.getWethPriceFeed());
//         priceFeed.updateAnswer(int256(1000e8));

//         vm.startPrank(liquidator);
//         deal(address(ssc), liquidator, debtToCover);
//         ssc.approve(address(ssc), debtToCover);
//         ssc.liquidate(address(weth), user, debtToCover);
//         vm.stopPrank();
//     }
// }
