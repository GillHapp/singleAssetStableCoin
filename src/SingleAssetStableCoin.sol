// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "../lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract SingleAssetStableCoin is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------ ERRORS ------------------
    error AmountMustBeMoreThanZero();
    error BurnAmountExceedsBalance();
    error NotZeroAddress();
    error NeedsMoreThanZero();
    error TransferFailed();
    error BreaksHealthFactor(uint256 healthFactorValue);
    error MintFailed();
    error HealthFactorOk();
    error HealthFactorNotImproved();

    // ------------------ IMMUTABLES ------------------
    address private immutable ETH_PRICE_FEED;

    // ------------------ CONSTANTS ------------------
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over-collateralization
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    // ------------------ STATE ------------------
    mapping(address => uint256) private collateralDeposited; // ETH balance in wei
    mapping(address => uint256) private sscMinted;

    // ------------------ EVENTS ------------------
    event CollateralDeposited(address indexed user, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, uint256 amount);
    event SSCMinted(address indexed user, uint256 indexed amount);
    event SSCBurned(address indexed user, uint256 indexed amount);

    // ------------------ MODIFIERS ------------------
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert NeedsMoreThanZero();
        _;
    }

    // ------------------ CONSTRUCTOR ------------------
    /**
     * @param ethUSDPriceFeedAddress Address of the ETH/USD Chainlink price feed
     */
    constructor(address ethUSDPriceFeedAddress) ERC20("SingleAssetStableCoin", "SSC") Ownable(msg.sender) {
        ETH_PRICE_FEED = ethUSDPriceFeedAddress;
    }

    // ------------------ USER FUNCTIONS ------------------

    /**
     * @notice Deposits ETH and mints SSC equal to the USD value of the ETH
     * @param amountSscToMint Amount of SSC to mint (1 SSC = $1)
     */
    function depositCollateralAndMintSsc(uint256 amountSscToMint) external payable {
        _depositCollateral();
        _mintSsc(amountSscToMint);
    }

    /**
     * @notice Burns SSC and redeems ETH collateral
     * @param amountCollateral Amount of ETH to redeem (in wei)
     * @param amountSscToBurn Amount of SSC to burn (in wei)
     */
    function redeemCollateralForSsc(uint256 amountCollateral, uint256 amountSscToBurn)
        external
        moreThanZero(amountCollateral)
        moreThanZero(amountSscToBurn)
        nonReentrant
    {
        _burnSsc(amountSscToBurn, msg.sender);
        _redeemCollateral(amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Redeems ETH collateral without burning SSC
     * @param amountCollateral Amount of ETH to redeem (in wei)
     */
    function redeemCollateral(uint256 amountCollateral) external moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Burns SSC to reduce debt
     * @param amount Amount of SSC to burn (in wei)
     */
    function burnSsc(uint256 amount) external moreThanZero(amount) nonReentrant {
        _burnSsc(amount, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Mints SSC (only callable by owner, used internally)
     * @param to Address to mint SSC to
     * @param amount Amount of SSC to mint (in wei)
     * @return bool Success indicator
     */
    function mint(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert NotZeroAddress();
        if (amount == 0) revert AmountMustBeMoreThanZero();
        _mint(to, amount);
        emit SSCMinted(to, amount);
        return true;
    }

    /**
     * @notice Burns SSC (callable by anyone with sufficient balance)
     * @param amount Amount of SSC to burn (in wei)
     */
    function burn(uint256 amount) public {
        uint256 balance = balanceOf(msg.sender);
        if (amount == 0) revert AmountMustBeMoreThanZero();
        if (balance < amount) revert BurnAmountExceedsBalance();
        _burn(msg.sender, amount);
        emit SSCBurned(msg.sender, amount);
    }

    /**
     * @notice Internal function to mint SSC after health factor check
     * @param amountSscToMint Amount of SSC to mint (in wei)
     */
    function _mintSsc(uint256 amountSscToMint) internal moreThanZero(amountSscToMint) nonReentrant {
        sscMinted[msg.sender] += amountSscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        _mint(msg.sender, amountSscToMint);
        emit SSCMinted(msg.sender, amountSscToMint);
    }

    /**
     * @notice Internal function to deposit ETH collateral
     */
    function _depositCollateral() internal nonReentrant {
        uint256 amountCollateral = msg.value;
        if (amountCollateral == 0) revert NeedsMoreThanZero();
        collateralDeposited[msg.sender] += amountCollateral;
        emit CollateralDeposited(msg.sender, amountCollateral);
    }

    /**
     * @notice Liquidates an under-collateralized position
     * @param user Address of the user to liquidate
     * @param debtToCover Amount of SSC debt to cover (in wei)
     */
    function liquidate(address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) revert HealthFactorOk();

        uint256 tokenAmountFromDebt = getTokenAmountFromUsd(debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebt * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        _redeemCollateral(tokenAmountFromDebt + bonusCollateral, user, msg.sender);
        _burnSsc(debtToCover, user);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) revert HealthFactorNotImproved();

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // ------------------ INTERNAL ------------------

    /**
     * @notice Redeems ETH collateral from one address to another
     * @param amountCollateral Amount of ETH to redeem (in wei)
     * @param from Address to redeem from
     * @param to Address to send ETH to
     */
    function _redeemCollateral(uint256 amountCollateral, address from, address to) private {
        if (amountCollateral > collateralDeposited[from]) revert AmountMustBeMoreThanZero();
        collateralDeposited[from] -= amountCollateral;
        emit CollateralRedeemed(from, to, amountCollateral);
        (bool success,) = payable(to).call{value: amountCollateral}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Burns SSC to reduce debt
     * @param amountSscToBurn Amount of SSC to burn (in wei)
     * @param from Address whose SSC is burned
     */
    function _burnSsc(uint256 amountSscToBurn, address from) private {
        if (amountSscToBurn > sscMinted[from]) revert AmountMustBeMoreThanZero();
        sscMinted[from] -= amountSscToBurn;
        IERC20(address(this)).safeTransferFrom(from, address(this), amountSscToBurn);
        _burn(address(this), amountSscToBurn);
        emit SSCBurned(from, amountSscToBurn);
    }

    /**
     * @notice Gets account information (SSC minted and collateral value)
     * @param user Address to query
     * @return totalSsc Total SSC minted by user
     * @return collateralValueUsd Collateral value in USD
     */
    function _getAccountInformation(address user) private view returns (uint256 totalSsc, uint256 collateralValueUsd) {
        totalSsc = sscMinted[user];
        collateralValueUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Calculates health factor for a user
     * @param user Address to query
     * @return Health factor (1e18 = 1)
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalSsc, uint256 collateralValueUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalSsc, collateralValueUsd);
    }

    /**
     * @notice Gets USD value of an ETH amount
     * @param amount Amount of ETH (in wei)
     * @return USD value (in wei)
     */
    function _getUsdValue(uint256 amount) private view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(ETH_PRICE_FEED).latestRoundData();
        /*
        2500 * 1e8.   and SSC is 1e18, so we need to adjust the precision
        2500 * 1e8 * 1e10 = 2500 * 1e18  but after that we also have the amount in wei, so we need to divide by 1e18
        for example amount is = 1e18 (2 ETH), then we get:
        (2500 * 1e8 * 1e10 * 2e18) / 1e18 = 2500 * 1e8 * 1e10 * 2 = 5000 * 1e18 USD 
        so we need to mint the SSC token 5000 cause they also have 1e18 precision
        so the final formula is:
        ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION
        */
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Calculates health factor based on SSC and collateral value
     * @param totalSsc Total SSC minted (in wei)
     * @param collateralValueUsd Collateral value in USD (in wei)
     * @return Health factor (1e18 = 1)
     */
    function _calculateHealthFactor(uint256 totalSsc, uint256 collateralValueUsd) internal pure returns (uint256) {
        if (totalSsc == 0) return type(uint256).max;
        uint256 collateralAdjusted = (collateralValueUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjusted * PRECISION) / totalSsc;
    }

    /**
     * @notice Reverts if health factor is below minimum
     * @param user Address to check
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert BreaksHealthFactor(healthFactor);
        }
    }

    // ------------------ VIEW ------------------

    /**
     * @notice Calculates health factor for given SSC and collateral values
     * @param totalSsc Total SSC minted (in wei)
     * @param collateralValueUsd Collateral value in USD (in wei)
     * @return Health factor (1e18 = 1)
     */
    function calculateHealthFactor(uint256 totalSsc, uint256 collateralValueUsd) external pure returns (uint256) {
        return _calculateHealthFactor(totalSsc, collateralValueUsd);
    }

    /**
     * @notice Gets account information
     * @param user Address to query
     * @return totalSsc Total SSC minted
     * @return collateralValueUsd Collateral value in USD
     */
    function getAccountInformation(address user) external view returns (uint256 totalSsc, uint256 collateralValueUsd) {
        return _getAccountInformation(user);
    }

    /**
     * @notice Gets USD value of an ETH amount
     * @param amount Amount of ETH (in wei)
     * @return USD value (in wei)
     */
    function getUsdValue(uint256 amount) external view returns (uint256) {
        return _getUsdValue(amount);
    }

    /**
     * @notice Gets ETH collateral balance of a user
     * @param user Address to query
     * @return ETH balance (in wei)
     */
    function getCollateralBalanceOfUser(address user) external view returns (uint256) {
        return collateralDeposited[user];
    }

    /**
     * @notice Gets USD value of a user’s ETH collateral
     * @param user Address to query
     * @return Collateral value in USD (in wei)
     */
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 amount = collateralDeposited[user];
        return _getUsdValue(amount);
    }

    /**
     * @notice Converts USD amount to ETH amount
     * @param usdAmountInWei USD amount (in wei)
     * @return ETH amount (in wei)
     */
    function getTokenAmountFromUsd(uint256 usdAmountInWei) public view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(ETH_PRICE_FEED).latestRoundData();
        if (price <= 0) revert AmountMustBeMoreThanZero();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    /**
     * @notice Gets ETH price feed address
     * @return Price feed address
     */
    function getEthPriceFeed() external view returns (address) {
        return ETH_PRICE_FEED;
    }

    /**
     * @notice Gets health factor for a user
     * @param user Address to query
     * @return Health factor (1e18 = 1)
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Gets liquidation threshold
     * @return Liquidation threshold (50 = 200% over-collateralization)
     */
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Gets liquidation bonus
     * @return Liquidation bonus (10 = 10%)
     */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /**
     * @notice Gets liquidation precision
     * @return Liquidation precision (100)
     */
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /**
     * @notice Gets minimum health factor
     * @return Minimum health factor (1e18)
     */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /**
     * @notice Gets precision constant
     * @return Precision (1e18)
     */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @notice Gets additional feed precision
     * @return Additional feed precision (1e10)
     */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    // ------------------ RECEIVE ------------------

    /**
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {}
}
