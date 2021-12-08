// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "./Commons.sol";

// interface that supports trigging `onReceive` event
interface IERC20Receiver {
    function onReceive(address _erc20Token, uint256 _amount) external;
}

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

// TODO: update code that requires winner claiming the jackpot instead of sending automatically as current !
contract CoinFlipJackpot is IERC20Receiver, ICoinFlipGameExtension, Ownable, TransferableFund(new address[](0)){
    ICoinFlipGameHouse public immutable gameHouse;
    uint256 public jackpotAmt;              // jackpot accumulated amount
    uint256 public accumulatedFromTime;     // the time when the jackpot begun to accummulate
    uint256 public immutable chanceToWin;   // chanceToWin = 1000 means probability of jackpot trigger is 0.1%
    address public lastWinner;
    uint256 public lastWonAmt;
    uint256 public lastWonTime;
    
    event Triggered(address indexed player, uint256 amount, uint256 indexed betId, uint256 time);
    event Withdraw(address indexed sender, address to, uint256 amount, uint256 time);
    
    
    constructor(ICoinFlipGameHouse _gameHouse, uint256 _chanceToWin) {
        require(_chanceToWin > 0, "Bad input");
        gameHouse = _gameHouse;
        chanceToWin = _chanceToWin;
    }
    
    
    modifier onlyGameHouse() {
        require(msg.sender == address(gameHouse), "Only Game House");
        _;
    }
    
    function onReceive(address , uint256 _amount) external override onlyGameHouse{
        jackpotAmt += _amount;
        if(accumulatedFromTime == 0){
            accumulatedFromTime = block.timestamp;
        }
    }
    
    
    function onInit() external override onlyGameHouse{
       
    }
    
    function onDeinit() external override onlyGameHouse{
        
    }
    
    function onBeforeBet(address _player, uint256 _amount, uint8 _side, uint256 _r) external override onlyGameHouse{
        
    }
    
    function onAfterBet(uint256 _betId) external override onlyGameHouse{
        
    }
    
    
    function onBeforeFinalize(uint56 _betId, uint256 _randomNum) external override onlyGameHouse{
        
    }
    
    function onAfterFinalize(uint56 _betId, uint256 _randomNum) external override onlyGameHouse{
        (,,,address player,,,,) = gameHouse.betRecords(_betId);
        // do the roll
        if((_randomNum % chanceToWin) == 0){
            // player wins the jackpot!
            uint256 transferedAmt = _safeTokenTransfer(address(gameHouse.paymentCurrency()), jackpotAmt, player);
            emit Triggered(player, transferedAmt, _betId, block.timestamp);
            jackpotAmt = 0;
            accumulatedFromTime = 0;
            lastWinner = player;
            lastWonAmt = transferedAmt;
            lastWonTime = block.timestamp;
            // update player storage
            gameHouse.playerStorage().updateGameData(address(0), player, false, true, jackpotAmt, 0);
        }
    }
    
    function onBeforeCancel(uint256 _betId, bool _canceledByPlayer) external override onlyGameHouse{
        
    }
    
    function onAfterCancel(uint256 _betId, bool _canceledByPlayer) external override onlyGameHouse{
        
    }
    
    // NOTE: have this function or not?
    function withdraw(address _to) external onlyOwner {
        uint256 withdrawalAmt = _safeTokenTransfer(address(gameHouse.paymentCurrency()), jackpotAmt, _to);
        emit Withdraw(msg.sender, _to, withdrawalAmt, block.timestamp);
        jackpotAmt = 0;
        accumulatedFromTime = 0;
    }
    
}