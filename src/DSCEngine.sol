// SPDX-License-Identifier: SEE LICENSE IN LICENSE

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
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
// view & pure functions

pragma solidity 0.8.20;

import {DecenralizedStableCoin} from "./DecentralizedStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard{
     ////////////////
    //   errors   //
    //////////////
    error DSC__NeedsMoreThanZero();
    error DSCEngine_Tokenaddress_and_PriceFeedAAddress_MustBeSameLength( );
    error DSCEngine_NotAllowedToken( );
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 _healthFactor);
    error DSCEngineMintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////
    // State Variables //
    //////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collateralised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;


    mapping(address token => address price) private s_priceFeeds; //tokento price feeds
    mapping(address user => mapping (address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecenralizedStableCoin private immutable i__dsc;

    ////////////////////
    //    Events     //
    //////////////////
    event CollateralDeposited (address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemedFrom,  address indexed redeemedTo,address token, uint256 amount); // if
        // redeemFrom != redeemedTo, then it was liquidated


    ////////////////
    // modifiers //
    //////////////
    modifier moreThanZero(uint256 amount){
        if (amount == 0){
            revert DSC__NeedsMoreThanZero();
        }
        _;
    }
    
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)){
            revert DSCEngine_NotAllowedToken( );
        }
        _;
    }
    ////////////////
    // Functions //
    //////////////
    constructor(
    address [] memory tokenAddresses, 
    address [] memory priceFeedAddresses, 
    address dscAddress) {
        // USD price feeds
        if( tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine_Tokenaddress_and_PriceFeedAAddress_MustBeSameLength( );
        }
        // foe exxp ETH / USD, BTC / USD
        for ( uint i = 0; i< tokenAddresses.length; i++){
            s_priceFeeds [tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i__dsc = DecenralizedStableCoin(dscAddress);
    }

    //External Functions
    
    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
    */
    function depositCollateralAndMintDSC(address tokenCollateralAddress,
         uint256 amountCollateral, uint256 amountDscToMint ) 
         external  {
               depositCollateral(tokenCollateralAddress, amountCollateral);
               mintDsc(amountDscToMint);
         }


    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */

    function depositCollateral(
        address tokenCollateralAddress,
         uint256 amountCollateral) 
         public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) 
         nonReentrant{
            s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
            emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
           bool success =  IERC20(tokenCollateralAddress).transferFrom((msg.sender), address (this), amountCollateral);
           if(!success ){
            revert DSCEngine__TransferFailed();
           }
         }

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external{

         burnDSC(amountDscToBurn);
         redeemCollateral(tokenCollateralAddress, amountCollateral);
         //redeeemCollateral already checks health factor.
    } 
    
    //in oredr to redeem collaterral 
    // helath facor must be over 1 after collateral pulled
    
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
    public moreThanZero(amountCollateral)
    nonReentrant 
      isAllowedToken(tokenCollateralAddress) {
        _redeemCollateral( msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);

      }
    
    //1. Cehck if the collateral value > DSC amount

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) 
    nonReentrant{
       s_DscMinted[msg.sender] += amountDscToMint;
        // if they minetd tooo much ($150) & have only 100
       _revertIfHealthFactorIsBroken(msg.sender);
       bool minted = i__dsc.mint(msg.sender, amountDscToMint);
       if(!minted){
        revert DSCEngineMintFailed();
       }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount){
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }


    function liquidate (address collateral, address user, uint256 debtToCover)
     external moreThanZero(debtToCover) nonReentrant(){
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
         
         // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        uint256 totalCollateralToRedeem = ( tokenAmountFromDebtCovered + bonusCollateral);
         _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem );
           // we need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

         uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);

     }

    function getHealthFactor () external view {}

    ////////////////////////////////
    //Private & Internal Functions //
    //////////////////////////////

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
        
    )
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i__dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i__dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted=  s_DscMinted[user ];
        collateralValueInUsd= getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidate a user 
       If user goes below 1 then they a=can get liquidated
     */
    function _healthFactor(address user) private view returns(uint256){
        //total DSC minter || total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD)/LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        //return (collateralValueInUsd / totaldscMinted); //
    }
    
    //1. checkhealth  factor -- do they have enough collateral?
        //2. and revert if they dont
    function _revertIfHealthFactorIsBroken(address user) internal view{
        uint256 userHealthFactor= _healthFactor(user);
        if (userHealthFactor  < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
     }
   
    /////////////////////////////////////
    //Public & External View Functions //
    ////////////////////////////////////
    
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd){
        //loop through each collateral token, get the amount tehy haave desposited, and map it to 
        // the price, to get the USDd value
        for (uint256 i =0; i< s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited [user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256){
          AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
          (, int256 price,,,) = priceFeed.latestRoundData();
          // 1 eth = $1000
          //Return the value from CL will be 1000 8 1e8

          return ((uint256( price) * ADDITIONAL_FEED_PRECISION)* amount)/PRECISION ; // (1000 * 1e8(1e18)) * 1000 *1e18
    }

}