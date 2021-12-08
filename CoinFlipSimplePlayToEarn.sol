// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "./Commons.sol";

// Game extension interface
interface IGameExtension {
    function onInit() external;
    function onDeinit() external;
}

// Game extension interface for Coin Flip game 
// that supports to execute custom code on some game actions
interface ICoinFlipGameExtension is IGameExtension {
    function onBeforeBet(address _player, uint256 _amount, uint8 _side, uint256 _r) external;
    function onAfterBet(uint256 _betId) external;
    function onBeforeFinalize(uint56 _betId, uint256 _randomNum) external;
    function onAfterFinalize(uint56 _betId, uint256 _randomNum) external;
    function onBeforeCancel(uint256 _betId, bool _canceledByPlayer) external;
    function onAfterCancel(uint256 _betId, bool _canceledByPlayer) external;
}


interface ICoinFlipGameHouse {
    function paymentCurrency() external view returns (IERC20);
    function playerStorage() external view returns (IArenaPlayerStorage);
    function betRecords(uint256 _betId) external view 
    returns(
    uint8 betSide,
    uint8 resolvedSide,
    uint8 state,
    address player,
    uint256 placedBlock,
    uint256 amount,
    uint256 rReqId,
    uint256 randomNum
    ); 
}


interface IArenaPlayerStorage {
    function updateGameData(
        address _tracker,
        address _player, 
        bool _asNewGame,
        bool _asWinner,
        uint256 _amountIn,
        uint256 _amountOut
        ) external;
}

contract CoinFlipSimplePlayToEarn is ICoinFlipGameExtension, Ownable, TransferableFund(new address[](0)){
    ICoinFlipGameHouse public immutable gameHouse;
    
    address public immutable rewardToken;
    
    struct PlayerRecord {
        uint128 accBetAmt;      // accumulated bet amount; in GWEI to save gas
        uint32 playedGames;     // total played games in recording period
        uint48 firstTime;       // first recored time
        uint48 lastTime;        // last recored time
    }
    mapping(address => PlayerRecord) public playerRecords;
    
    mapping(address => uint256) public pendingReward;
    
    uint48 public recordPeriod;        // in seconds
    
    // events
    event ClaimReward(address indexed player, uint256 amount, uint256 time);
    
    constructor(ICoinFlipGameHouse _gameHouse, address _rewardToken) {
        gameHouse = _gameHouse;
        rewardToken = _rewardToken;
    }
    
    
    modifier onlyGameHouse() {
        require(msg.sender == address(gameHouse), "Only Game House");
        _;
    }
    
    
    function onInit() external override onlyGameHouse{
       
    }
    
    function onDeinit() external override onlyGameHouse{
        
    }
    
    function onBeforeBet(address _player, uint256 _amount, uint8 _side, uint256 _r) external override onlyGameHouse{
        
    }
    
    function onAfterBet(uint256 _betId) external override onlyGameHouse{
        (,,,address player,,uint256 amount,,) = gameHouse.betRecords(_betId);
       PlayerRecord memory rec = playerRecords[player];
       uint256 currTime = block.timestamp;
       if(rec.firstTime == 0){
           rec.accBetAmt = uint128(amount / 1e9);
           rec.playedGames = 1;
           rec.firstTime = uint48(currTime);
           rec.lastTime = uint48(currTime);
       } else if(currTime > rec.firstTime + recordPeriod){
           // calculate and add reward for player
           uint256 rewardAmt = _calculateReward(rec);
           pendingReward[player] += rewardAmt;
           // update player storage
           gameHouse.playerStorage().updateGameData(address(0), player, false, true, rewardAmt, 0);
           // recording period rolling out
           rec.accBetAmt = uint128(amount / 1e9);
           rec.playedGames = 1;
           rec.firstTime = uint48(currTime);
           rec.lastTime = uint48(currTime);
       }else{
           rec.playedGames += 1;
           rec.accBetAmt += uint128(amount / 1e9);
           rec.lastTime = uint48(currTime);
       }
       playerRecords[player] = rec;
    }
    function onBeforeFinalize(uint56 _betId, uint256 _randomNum) external override onlyGameHouse{
        
    }
    
    function onAfterFinalize(uint56 _betId, uint256 _randomNum) external override onlyGameHouse{
        
    }
    
    function onBeforeCancel(uint256 _betId, bool _canceledByPlayer) external override onlyGameHouse{
        
    }
    
    function onAfterCancel(uint256 _betId, bool _canceledByPlayer) external override onlyGameHouse{
        
    }
    
    function claimReward() external {
        uint256 unclaimedReward =  pendingReward[msg.sender];
        if(unclaimedReward > 0){
            uint256 transferedAmt = _safeTokenTransfer(rewardToken, unclaimedReward, msg.sender);
            pendingReward[msg.sender] -= transferedAmt;
            emit ClaimReward(msg.sender, transferedAmt, block.timestamp);
        }
    }
    
    function _calculateReward(PlayerRecord memory _playerRec) virtual internal returns(uint256){
        // TODO: update later
        if(_playerRec.playedGames > 0){
            return 1e18;   
        }
        return 0;
    }
}