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


contract SampleExtension is ICoinFlipGameExtension{
    ICoinFlipGameHouse public immutable gameHouse;
    
    mapping(address => uint256) public playerBetAmt;
    
    constructor(ICoinFlipGameHouse _gameHouse) {
        gameHouse = _gameHouse;
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
        playerBetAmt[player] += amount;
    }
    function onBeforeFinalize(uint56 _betId, uint256 _randomNum) external override onlyGameHouse{
        
    }
    
    function onAfterFinalize(uint56 _betId, uint256 _randomNum) external override onlyGameHouse{
        
    }
    
    function onBeforeCancel(uint256 _betId, bool _canceledByPlayer) external override onlyGameHouse{
        
    }
    
    function onAfterCancel(uint256 _betId, bool _canceledByPlayer) external override onlyGameHouse{
        
    }
}