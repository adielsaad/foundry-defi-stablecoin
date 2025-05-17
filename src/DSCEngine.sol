// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DecentralizedStableCoin Engine
 * @author Adiel Saad
 * This system to be as minimal as possible, and have the tokens maintain a 1 token == 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous collateral
 * - Algorithmic stability
 * - Dollar pegged
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should alwaays be "over-collateralized". At no point should the value of the collateral be less than or equal to the value of the DSC minted.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 *
 */
contract DSCEngine is ReentrancyGuard {
    //////////////
    /// Errors ///
    //////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__BurnFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////
    /// State Variables ///
    ///////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATOR_BONUS = 10; // 10% bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 100%

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////
    /// Events ///
    //////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);
   
    /////////////////
    /// Modifiers ///
    /////////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //////////////////
    ///  Functions ///
    //////////////////

    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        // USD Price Feeds
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
        }
        // For example ETH/USD Price Feeds
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    //////////////////////////
    /// External Functions ///
    //////////////////////////

    /**
     * @notice This function will deposit collateral and mint DSC in one transaction
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of collateral to deposit
     * @param _amountDSCToMint The amount of DSC to mint
     */
    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDSCToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDSC(_amountDSCToMint);
    }

    /*
    * @notice Follows CEI pattern - Checks, Effects, Interactions
    * @param _tokenCollateralAddress The address of the token to deposit as collateral
    * @param _amountCollateral The amount of collateral to deposit
    */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice This function will burn DSC and redeem collateral in one transaction
     * @param _tokenCollateralAddress The address of the token to redeem collateral for
     * @param _amountCollateral The amount of collateral to redeem
     * @param _amountDSCToBurn The amount of DSC to burn
     */
    function redeemCollateralForDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDSCToBurn
    ) external {
        burnDSC(_amountDSCToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
        // redeem collateral already checks for health factor
    }

    /**
     * @notice This function will redeem collateral for DSC
     * @param _tokenCollateralAddress The address of the token to redeem collateral for
     * @param _amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral) public moreThanZero(_amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice Follows CEI pattern - Checks, Effects, Interactions
    * @param _amount The amount of DSC to mint
    * @notice They must have more collateral value than the minimum threshold
    */
    function mintDSC(uint256 _amount) public moreThanZero(_amount) nonReentrant {
        s_DSCMinted[msg.sender] += _amount;
        // If they minted too much ($150 DSC, $100 of ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amount);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
    * @notice This function will burn DSC
    * @param _amount The amount of DSC to burn
    */
    function burnDSC(uint256 _amount) public moreThanZero(_amount)  {
        _burnDSC(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice This function will liquidate a user's position
    * @notice  You can only liquidate a user if their health factor is less than MIN_HEALTH_FACTOR
    * @param _collateralToken The address of the token to liquidate collateral for
    * @param _userToLiquidate The address of the user to liquidate (the user who has broken the health factor)
    * @param _debtToCover The amount of DSC to cover
    */
    function liquidate(
        address _collateral,
        address _userToLiquidate,
        uint256 _debtToCover
    ) external moreThanZero(_debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(_userToLiquidate);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            _collateral,
            _debtToCover
        );
        // Give the liquidator the collateral with 10% bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATOR_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(_userToLiquidate, msg.sender, _collateral, totalCollateralToRedeem);
        _burnDSC(_debtToCover, _userToLiquidate, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(_userToLiquidate);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address _user) external view returns (uint256) {}

    /////////////////////////////////////////
    /// Private & Internal View Functions ///
    /////////////////////////////////////////


    /*
    * @dev Low-level function to burn DSC, do not call unless the function calling this has checked the health factor being broken
    */
    function _burnDSC(uint256 _amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= _amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), _amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDSCToBurn);
    }

    function _redeemCollateral(address from, address to, address _tokenCollateralAddress, uint256 _amountCollateral) private {
        s_collateralDeposited[from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(from, to, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(to, _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 totalCollateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[_user];
        totalCollateralValueInUSD = getAccountCollateralValue(_user);
        return (totalDSCMinted, totalCollateralValueInUSD);
    }

    /*
    1. Get the amount of collateral
    2. Get the amount of DSC minted
    3. Calculate the health factor
    4. Return how close to liquidation they are
    If the health factor is less than 1, they are under-collateralized and can be liquidated.
    If the health factor is greater than 1, they are over-collateralized and can continue to hold their position.
    * @notice Health factor is a value that is used to determine if a user is over-collateralized or under-collateralized.
    * @param _user The address of the user to check the health factor of
    * @return The health factor of the user
    */
    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUSD) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        /*
        If the collateralAdjustedForThreshold is less than the totalDSCMinted, the user is under-collateralized and can be liquidated.
        If the collateralAdjustedForThreshold is greater than the totalDSCMinted, the user is over-collateralized and can continue to hold their position.
        For example, if the collateralAdjustedForThreshold is 100 and the totalDSCMinted is 50, the user is 2x over-collateralized.
        So the health factor is 200%
        */
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        /* 1. Check health factor
           2. Revert if health factor is broken
        */
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////////////////////
    /// Public & External View Functions ////
    /////////////////////////////////////////

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUSD) {
        // Loop through each collateral token
        // Get the amount of collateral deposited by the user
        // Map it to the price to get the collateral value in USD
        // Return the total collateral value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    function getUsdValue(address _tokenAddress, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_tokenAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1ETH = $1000
        // The returned value from ChainLink will be 1000 * 1e8 = 1000000000
        // We want to convert it to 1000 * 1e18 = 1000000000000000000
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION * _amount) / PRECISION) / ADDITIONAL_FEED_PRECISION; // (1000 * 1e10 * 1e18) / 1e18 = 1000 * 1e10 = 10000000000
    }
}
