// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "./Commons.sol";
import "./ArenaPlayerStorage.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

// Interface for game master
interface IGameMaster {
    function owner() external view returns(address);
    function paymentCurrency() external view returns(IERC20);
    function playerStorage() external view returns(IArenaPlayerStorage);
    function isTrustedDealer(address _dealer) external view returns(bool);
    function isRegisteredGameHouse(address _toCheck) external view returns(bool);
    function onCollectOperationFee(uint256 _amount) external;
}

// Game house tracker interface
interface IGameHouseTracker {
    function current() external view returns(IGameHouse);
    function histItem(uint256 _index) external view returns(IGameHouse);
    function totalHistItems() external view returns(uint256);
    function setCurrent(IGameHouse _newCurrent) external;
}


// Interface for betting game house
interface IGameHouse {
    function owner() external view returns(address);
    function gameMaster() external view returns(IGameMaster);
    function tracker() external view returns(IGameHouseTracker);
    function paymentCurrency() external view returns(IERC20);
    function playerStorage() external view returns(IArenaPlayerStorage);
    function availableFund() external view returns(uint256);
    function feePerBet() external view returns(uint256);
    function operationFeePerBet() external view returns(uint256);
    function totalFeeAllocators() external view returns(uint256);
    function feeAllocatorAt(uint256 _index) external view returns(address _target, uint256 _share);
    function accumulatedFee() external view returns(uint256);
    
    function depositFund(uint256 _amount) external;
    function withdrawFund(uint256 _amount, address _withdrawTo) external;
    function setPlayerStorage(IArenaPlayerStorage _playerStorge) external;
    function setOperationFee(uint256 _value) external;
    function onUnreg(address _withdrawTo) external;
    function migrate(IGameHouse _toGameHouse) external;
    function onMigration(IGameHouse _fromGameHouse) external;
    function transferOwnership(address newOwner) external;
    
    function hasExtension(address _toCheck) external view returns(bool);
    function addExtension(IGameExtension _ex) external;
    function removeExtension(IGameExtension _ex) external;
    
    function transferGameMaster(IGameMaster _newGameMaster) external;
}

// Interface for game house factory
interface IGameHouseFactory {
    function create(IGameMaster _gameMaster, address _defaultFeeAllocator, address _tracker) external returns(IGameHouse);
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
    function onBeforeCancel(uint256 _betId) external;
    function onAfterCancel(uint256 _betId) external;
}


interface iPEFI is IERC20 {
    function leave(uint256 share) external;
}

// Interface of old game house contract
interface ICoinFlipGameHouseV1 is IGameHouse {
    function minBetAmt() external view returns(uint256);
    function maxBetAmt() external view returns(uint256);
    function committedSecretHashes(uint256 _betId) external view returns(uint256);
    function existingSecretHash(uint256 _hash) external view returns(bool);
    function hadPlayed(address _player) external view returns(bool);
    function betRecords(uint256 _betId) external view 
    returns(
    uint8 betSide,
    uint8 revealSide,
    uint8 state,
    address player,
    uint256 amount,
    uint256 r,
    uint256 placedBlock
    );
    function betState(uint256 _betId) external view returns(uint8 _state, uint256 _placedBlock, uint256 _currentBlock);
    function statsData() external view returns(
    uint128 betAmt,
    uint128 payoutAmt,
    uint56 currentBetId,
    uint56 nextSetupBetId,
    uint56 finalizedGames,
    uint56 canceledGames,
    uint32 uniquePlayers
    );
}

interface IVRFConsumer {
    function requestRandomNumber() external returns(bytes32);
}

interface ICoinFlipGameHouseVRF is IGameHouse {
    function fulfillRandomness(bytes32 _requestId, uint256 _randomNum) external;
}

contract VRFConsumer is VRFConsumerBase, Withdrawable, Ownable{
    // TODO: Settings for VRF client. Please change them when deploy on prod environment -------------------------
    address constant internal LINK_TOKEN = 0x326C977E6efc84E512bB9C30f76E30c160eD06FB;
    address constant internal VRF_CONTRACT = 0x8C7382F9D8f56b33781fE506E897a4F1e2d17255;
    bytes32 constant internal KEY_HASH = 0x6e75b569a01ef56d18cab6a8e71e6600d6ce853834d4a5748b720d06f878b3a4;
    uint256 constant internal VRF_DEFAULT_CONSUMING_FEE = 0.0001 * ( 10 ** 18); // 0.0001 LINK (Varies by network)
    // -----------------------------------------------------------------------------------------------------------
    
    IGameMaster public immutable gameMaster;
    
    // mapping: requestId => caller
    mapping(bytes32 => address) public callerOf;
    
    uint256 public consumingFee;
    
    constructor(IGameMaster _gameMaster) 
    VRFConsumerBase(VRF_CONTRACT, LINK_TOKEN)
    Withdrawable(new address[](0))
    {
        gameMaster = _gameMaster;
        consumingFee = VRF_DEFAULT_CONSUMING_FEE;
    }
    
    /**
     * Request a random number
     * (can be called only by registered game house)
     */    
    function requestRandomNumber() external returns(bytes32){
        require(gameMaster.isRegisteredGameHouse(msg.sender), "Only registered game house");
        require(LINK.balanceOf(address(this)) >= consumingFee, "Not enough LINK");
        bytes32 requestId = requestRandomness(KEY_HASH, consumingFee);
        callerOf[requestId] = msg.sender;
        return requestId;
    }
    
    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        address oriCaller =  callerOf[requestId];
        if(oriCaller != address(0)){
            ICoinFlipGameHouseVRF(oriCaller).fulfillRandomness(requestId, randomness);
        }
    }
    
    
    function setConsumingFee(uint256 _value) external onlyOwner {
        consumingFee = _value;
    }
    
    function withdraw(address _token, uint256 _amount, address _to) external onlyOwner {
        _safeTokenTransfer(_token, _amount, _to);
    }
}

contract GameHouseTracker is IGameHouseTracker {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    IGameHouse public override current;
    
    EnumerableSet.AddressSet private histItems;
    
    constructor(IGameHouse _gameHouse){
        current = _gameHouse;
    }
    
    function histItem(uint256 _index) external view override returns(IGameHouse){
        return IGameHouse(histItems.at(_index));
    }
    
    function totalHistItems() external view override returns(uint256){
        return histItems.length();
    }
    
    function setCurrent(IGameHouse _newCurrent) override external {
        require(msg.sender == address(current), "Only current house can call");
        require(address(_newCurrent.paymentCurrency()) == address(current.paymentCurrency()), "Invalid payment currency");
        histItems.add(address(current));
        current = _newCurrent;
    }
}


/*
 *  Base class for any single betting game house contract.
 *  This contract does not deal with any game logic; it just deals only with game house fund management
 */
contract GameHouseBase is IGameHouse, Ownable, AccessControl {
    using SafeERC20 for IERC20;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    
    uint256 internal constant MAX_BIPS = 10000;
    
    bytes32 public constant GAME_OPERATION_ROLE = keccak256("GAME_OPERATION_ROLE"); 
    
    // TODO: PEFI token: please change to the proper value on deployment
    address internal PEFI = 0xB2de466647801d4FB5C9b3eeFcC7346af74846F5;
    
    // TODO: iPEFI token: please change to the proper value on deployment
    address internal NEST = 0x41fdBb7DF05a100f0cc1C67cE8970A22934f0403;
    
    // Game master that controls trusted dealers
    IGameMaster public override gameMaster;
    
    // Tracker
    IGameHouseTracker public override tracker;
    
    // Payment token (ERC20) for game
    IERC20 public immutable override paymentCurrency;
    
    // Player storage
    IArenaPlayerStorage public override playerStorage;
    
     // The operational fee collected for Penguin Finance per game (divided by 10,000; so 80 means 0.8% of bet amount) 
    uint public operationFeePerBet;
    
     // The fee collected by game house per game (divided by 10,000; so 80 means 0.8% of bet amount)
    uint256 public feePerBet = 100;
    
    struct FeeAllocator {
        address target;     // Address that a share portion of fee will be distributed to
        uint256 share;      // Distributed share of fee (devided by 10,000)
    }
    
    // List of fee allocators
    FeeAllocator[] private feeAllocators;
    
    // accumulated fee amount
    uint256 public override accumulatedFee;

    
    // Total fund (in paymentCurrency) that is locked in this contract
    uint256 public totalLockedFund;
    
    // Total fund (in paymentCurrency) that is locked by all pending games
    uint256 public fundLockedByGames;
    
    // Game extentions
    EnumerableSet.AddressSet private gameExtensions;
    
    // running flag: set to `false` to emergency stop
    bool public isRunning = true;
    
    constructor(IGameMaster _gameMaster, address _defaultFeeAllocator, address _tracker){
        gameMaster = _gameMaster;
        
        paymentCurrency = _gameMaster.paymentCurrency();
        
        playerStorage = _gameMaster.playerStorage();
        
        if(_defaultFeeAllocator != address(0)){
            feeAllocators.push(FeeAllocator({
                target: _defaultFeeAllocator,
                share: MAX_BIPS
            }));
        }
        
        if(_tracker == address(0)){
            tracker = new GameHouseTracker(this);
        } else {
            tracker = IGameHouseTracker(_tracker);
        }
        
        // grant "default admin" role for contract owner
        _grantRole(DEFAULT_ADMIN_ROLE, owner());
        // also grant game operation role for contract owner
        _grantRole(GAME_OPERATION_ROLE, owner());
    }
    
    modifier onlyGameMaster() {
        require(msg.sender == address(gameMaster), "Only Game Master can access");
        _;
    }
    
     modifier onlyTrusterDealer() {
        require(gameMaster.isTrustedDealer(msg.sender), "Only trusted dealer can access");
        _;
    }
    
    modifier onlyGameOperator() {
        require(
            hasRole(GAME_OPERATION_ROLE, msg.sender) ||
            msg.sender == owner(), 
            "Only game owner/operators can access"
            );
        _;
    }
    
    
    // The fund that is available for withdrawal from this game house contract
    function availableFund() public view override returns(uint256){
        return (paymentCurrency.balanceOf(address(this)) - totalLockedFund);
    }
    
    // Total fee that player is charged per bet.
    // That includes Penguine operation fee and Game House fee
    function totalFeePerBet() public view returns(uint256){
        uint256 totalFee = operationFeePerBet + feePerBet;
        if(totalFee > MAX_BIPS){
            totalFee = MAX_BIPS;
        }
        return totalFee;
    }   
    
    function totalFeeAllocators() external view override returns(uint256){
        return feeAllocators.length;
    }
    
    function feeAllocatorAt(uint256 _index) external view override returns(address _target, uint256 _share){
        require(_index < feeAllocators.length, "Out of range");
        _target = feeAllocators[_index].target;
        _share = feeAllocators[_index].share;
    }
    
    function depositFund(uint256 _amount) external override{
        // Transfer fund
        paymentCurrency.safeTransferFrom(msg.sender, address(this), _amount);
        // Lock fund
        _lockFund(_amount);
    }
    
    function withdrawFund(uint256 _amount, address _withdrawTo) external override onlyOwner{
        require(_amount <= availableFund(), "Not enough available fund to withdraw");
        // Transfer fund
        paymentCurrency.safeTransfer(_withdrawTo, _amount);
    }
    
    // This function can be called by Game Master only when this game house is un-registered from game master
    function onUnreg(address _withdrawTo) external override onlyGameMaster{
        // Release all fund EXCEPT fund locked by game currently
        uint256 fundToRelease = paymentCurrency.balanceOf(address(this)) - fundLockedByGames;
        if(fundToRelease > 0){
            totalLockedFund = fundLockedByGames;
            paymentCurrency.safeTransfer(_withdrawTo, fundToRelease);
        }
    }
    
    
    // Only Game Master can call this function to migrate game house contract
    function migrate(IGameHouse _toGameHouse) external override onlyGameMaster{
        // Release all fund EXCEPT fund locked by game currently
        uint256 fundToRelease = paymentCurrency.balanceOf(address(this)) - fundLockedByGames;
        if(fundToRelease > 0){
            // deposit fund to new game house contract
            paymentCurrency.safeApprove(address(_toGameHouse), fundToRelease);
            _toGameHouse.depositFund(fundToRelease);
            // update total locked fund
            totalLockedFund = fundLockedByGames;
        }
        // set tracker current house to new one
        tracker.setCurrent(_toGameHouse);
        // stop game itself
        isRunning = false;
    }
    
     // Only game master (owned by Penguin Finance) can call this function on game house migration
    function onMigration(IGameHouse _fromGameHouse) public virtual override onlyGameMaster{
        // Copy fee settings
        feePerBet = _fromGameHouse.feePerBet();
        operationFeePerBet = _fromGameHouse.operationFeePerBet();
        // Copy fee allocators
        uint256 totalAllocators = _fromGameHouse.totalFeeAllocators();
        for(uint256 i=0; i<totalAllocators; i++){
            (address target, uint256 share) = _fromGameHouse.feeAllocatorAt(i);
            feeAllocators.push(FeeAllocator({
                target: target,
                share: share
            }));
        }
        // Also copy accumulated fee
        accumulatedFee = _fromGameHouse.accumulatedFee();
    }
    
    function addGameOperator(address _toAdd) external {
        grantRole(GAME_OPERATION_ROLE, _toAdd);
    }
    
    function removeGameOperator(address _toRemove) external {
        revokeRole(GAME_OPERATION_ROLE, _toRemove);
    }
    
    // start game
    function start() external onlyGameOperator{
        isRunning = true;
    }
    
    // stop game
    function stop() external onlyGameOperator{
        isRunning = false;
    }
    

    // Only game master (owned by Penguin Finance) can call this function
    function setPlayerStorage(IArenaPlayerStorage _newPlayerStorage) external override onlyGameMaster{
        playerStorage = _newPlayerStorage;
    }
    
    
    // Only game master (owned by Penguin Finance) can call this function
    function setOperationFee(uint256 _value) external override onlyGameMaster {
        require(_value + feePerBet <= MAX_BIPS, "Value exceeded");
        operationFeePerBet = _value;
    }
    
    function setFee(uint256 _value) external onlyOwner {
        require(_value + operationFeePerBet <= MAX_BIPS, "Value exceeded");
        feePerBet = _value;
    }
    
    // warning: call this method will replace all current allocators
    function setFeeAllocators(address[] memory _targets, uint256[] memory _shares) external onlyOwner{
        uint256 numAllocators = _targets.length;
        require(numAllocators > 0, "At least 1 allocator required");
        require(numAllocators == _shares.length, "Invalid input: arrays length mismatched");
        
        uint256 totalShares;
        for(uint i=0; i<numAllocators; i++){
            totalShares += _shares[i];
        }
        require(totalShares <= MAX_BIPS, "Invalid total shares");
        
        if(feeAllocators.length > 0){
            // clear out current allocators list
             delete feeAllocators;   
        }
        
        for(uint i=0; i<numAllocators; i++){
            feeAllocators.push(FeeAllocator({
                target: _targets[i],
                share: _shares[i]
            }));
        }
        
    }
    
    function totalExtensions() view public returns(uint256){
        return gameExtensions.length();
    }
    
    function extensionAt(uint256 _index) view public returns(IGameExtension){
        return IGameExtension(gameExtensions.at(_index));
    }
    
    function hasExtension(address _toCheck) view public override returns(bool) {
        return (gameExtensions.contains(_toCheck));
    }
    
    function addExtension(IGameExtension _ex) external override onlyGameMaster {
        require(gameExtensions.add(address(_ex)), "Add game extension failed");
        _ex.onInit();
    } 
    
    function removeExtension(IGameExtension _ex) external override onlyGameMaster {
        require(gameExtensions.remove(address(_ex)), "Remove game extension failed");
        _ex.onDeinit();
    }
    
    function transferOwnership(address _newOwner) public virtual override(Ownable, IGameHouse) onlyOwner {
        // add new owner to default admin role
        _grantRole(DEFAULT_ADMIN_ROLE, _newOwner);
        // also grant game operation role for new owner
        _grantRole(GAME_OPERATION_ROLE, _newOwner);
        
        // Remove current owner from roles 
        _revokeRole(GAME_OPERATION_ROLE, owner()); 
        _revokeRole(DEFAULT_ADMIN_ROLE, owner()); 
        
        // Transfer ownership
        Ownable.transferOwnership(_newOwner);
    }
    
    function owner() public view virtual override(Ownable, IGameHouse) returns (address) {
        return Ownable.owner();
    }
    
    // For case we need to update game master contract
    function transferGameMaster(IGameMaster _newGameMaster) external override onlyGameMaster {
        gameMaster = _newGameMaster;
    }
    
   
    // The fund that is freely to lock by games
    function _availableFundToLockByGames() internal view returns(uint256){
       return (paymentCurrency.balanceOf(address(this)) - fundLockedByGames); 
    }
    
     function _lockFund(uint256 _amount) internal{
        require(_amount <= availableFund(), "Not enough fund to lock");
        totalLockedFund += _amount;
    }
    
    function _releaseFund(uint256 _amount) internal {
        require(_amount <= totalLockedFund, "Cannot release exceeded amount");
        totalLockedFund -= _amount;
    }
    
    function _lockFundByGame(uint256 _amount) internal{
        uint256 freeToGameLockAmt = totalLockedFund - fundLockedByGames;
        if(_amount > freeToGameLockAmt){
            uint256 lockMoreAmt = _amount -  freeToGameLockAmt;
            _lockFund(lockMoreAmt);
        }
        fundLockedByGames += _amount;
    }
    
    function _releaseFundByGame(uint256 _amount) internal{
        require(_amount <= fundLockedByGames, "Cannot release exceeded amount");
        fundLockedByGames -= _amount;
        totalLockedFund -= _amount;
    }
    
    // Collect fee for game house
    function _collectFee(uint256 _amount) internal {
        accumulatedFee += _amount;
        uint256 numAllocators = feeAllocators.length;
        for(uint256 i=0; i<numAllocators; i++){
            uint256 amtToDistribute = (_amount * feeAllocators[i].share) / MAX_BIPS;
            address target = feeAllocators[i].target;
            if(address(paymentCurrency) == NEST && target == NEST){
                _sendToNest(amtToDistribute);
            }else{
                paymentCurrency.safeTransfer(target, amtToDistribute);
            }
        }
    }
    
    // Collect operation fee for Penguin Finance
    function _collectOperationFee(uint256 _amount) internal{
       if(_amount > 0) {
           paymentCurrency.safeTransfer(address(gameMaster), _amount);
           gameMaster.onCollectOperationFee(_amount);
       }
    }
    
    // Send to NEST
    function _sendToNest(uint256 _amount) internal{
        iPEFI(NEST).leave(_amount);
        uint256 pefiToSend = IERC20(PEFI).balanceOf(address(this));
        IERC20(PEFI).safeTransfer(NEST, pefiToSend);
    }
}

/**
 * @title Arena Coin Flip mini-game implementation with Chainlink VRF
 * @dev Implement gameplay logic of Arena Coin Flip mini-game
 */
contract CoinFlipGameHouseVRF is GameHouseBase {
    using SafeERC20 for IERC20;
    
    uint8 public constant COIN_SIDE_UP = 1;
    uint8 public constant COIN_SIDE_DOWN = 2;
    
    uint8 internal constant GAME_STATE_PENDING = 1;
    uint8 internal constant GAME_STATE_RANDOMNESS_FULFILLED = 2;
    uint8 internal constant GAME_STATE_FINALIZED = 0x80;
    uint8 internal constant GAME_STATE_CANCELED = 0xff;
    
    IVRFConsumer public immutable vrfConsumer;
    
    // Game house this contract has been migrated from
    ICoinFlipGameHouseV1 public oldGameHouse;
    // The bet ID at the migration time
    uint256 public startCurrentBetId;

    // Min betable amount
    uint256 public minBetAmt = 1e18;
    // Max betable amount
    uint256 public maxBetAmt = 1000 * 1e18;
    
    // Stats data structure (try to "pack" data for saving data storage slot)
    struct StatsData {
        uint128 betAmt;         // Total bet amount (in GWEI to save gas)
        uint128 payoutAmt;      // Total payout amount (in GWEI to save gas)
        uint56 currentBetId;
        uint56 finalizedGames;
        uint56 canceledGames;
        uint32 uniquePlayers;
    }
    
    // Stats data of this game
    StatsData public statsData;
    
    // Indicate that user had ever played the game or not
    mapping(address => bool) private pHadPlayed;
    
    // Bet record data structure
    struct BetRecord {
        uint8 betSide;          // Bet side: 1 - up, 2 - down
        uint8 revealSide;       // Reveal side: 1 - up, 2 - down
        uint8 state;            // Game state: 1-pending, 2-finalized, 3-canceled
        address player;         // Player address
        uint256 amount;         // Bet amount
        uint256 placedBlock;    // Block number where the bet placed
        uint256 vrfRequestId;   // VRF request ID
        uint256 randomNum;      // Random number fulfilled from Chainlink VRF
    }
    
    // Bet records in the form: betId => BetRecord
    mapping(uint256 => BetRecord) private pBetRecords;
    
    // Mapping: vrfRequestId => betId
    mapping(uint256 => uint256) public betOfRequest;
    
    // The number of blocks (that passed from bet placed block) that allows user to cancel the game
    uint256 public gameCancelablePassedBlocks = 1001;
    
    // Events
    event BetPlace(uint256 indexed betId, uint256 vrfRequestId);
    event FulfillRandomness(uint256 indexed betId);
    event FinalizeGame(uint256 indexed betId, uint256 payoutAmt, uint256 totalFee);
    event CancelGame(uint256 indexed betId);
    
    
    constructor(IGameMaster _gameMaster, address _defaultFeeAllocator, address _tracker, IVRFConsumer _vrfConsumer) 
    GameHouseBase(_gameMaster, _defaultFeeAllocator, _tracker){
        vrfConsumer = _vrfConsumer;
        startCurrentBetId = 1;
        statsData.currentBetId = 1;
    }
    
    function setMaxBetAmount(uint256 _value) public onlyOwner {
        require(_value >= minBetAmt, "Max value cannot be lesser than min value");
        maxBetAmt = _value;
    }
    
    function setMinBetAmount(uint256 _value) public onlyOwner {
        require(_value <= maxBetAmt, "Min value cannot be greater than max value");
        minBetAmt = _value;
    }
    
    function setGameCancelablePassedBlocks(uint256 _value) external onlyOwner {
        gameCancelablePassedBlocks = _value;
    }
    
    // Check whether the game is ready or not
    function isGameReady() public view returns(bool){
        return isRunning;
    }
    
    // Helper method for dealer bot
    function betState(uint256 _betId) external view returns(uint8 _state, uint256 _placedBlock, uint256 _currentBlock) {
        if(_betId < startCurrentBetId){
            // query the bet from old game house
            return oldGameHouse.betState(_betId);
        } else{
            _state = pBetRecords[_betId].state;
            _placedBlock = pBetRecords[_betId].placedBlock;
            _currentBlock = block.number;
        }
    }
    
    function betRecords(uint256 _betId) external view 
    returns(
    uint8 betSide,
    uint8 revealSide,
    uint8 state,
    address player,
    uint256 amount,
    uint256 r,
    uint256 placedBlock,
    uint256 vrfRequestId,
    uint256 randomNum
    ){
        if(_betId < startCurrentBetId){
            // query the bet from old game house
             (betSide, revealSide, state, player, amount, r, placedBlock) = oldGameHouse.betRecords(_betId);
             vrfRequestId = 0;
             randomNum = 0;
        }else{
            betSide = pBetRecords[_betId].betSide;
            revealSide = pBetRecords[_betId].revealSide;
            state = pBetRecords[_betId].state;
            player = pBetRecords[_betId].player;
            amount = pBetRecords[_betId].amount;
            r = 0;
            placedBlock = pBetRecords[_betId].placedBlock;
            vrfRequestId = pBetRecords[_betId].vrfRequestId;
            randomNum = pBetRecords[_betId].randomNum;
        }
    }
    
    // Get the min/max bet amount that player can place at the moment
    // (frontend can call this function to limit bet values on UI)
    function getBetableAmtRange() public view returns(uint256 _minValue, uint256 _maxValue){
        if(!isGameReady()){
            return (0, 0);
        }
        
        uint256 availableFundToLockByGames = _availableFundToLockByGames();
        
        if(availableFundToLockByGames < 2*minBetAmt){
            // Bet is not allowed
            _minValue = 0;
            _maxValue = 0;
        } else if(availableFundToLockByGames < 2*maxBetAmt){
            _minValue = minBetAmt;
            _maxValue = availableFundToLockByGames / 2;
        } else{
            _minValue = minBetAmt;
            _maxValue = maxBetAmt;
        }
        
    }
    
    function totalPendingGames() external view returns(uint256){
        return (statsData.currentBetId - statsData.finalizedGames - statsData.canceledGames);
    }
    
     
    function hadPlayed(address _player) public view returns(bool){
        if(address(oldGameHouse) != address(0)){
            return (pHadPlayed[_player] || oldGameHouse.hadPlayed(_player)); 
        } else {
            return pHadPlayed[_player]; 
        }
    }
    
    // Player calls this function to place the bet
    function placeBet(uint256 _amount, uint8 _side, uint256) external {
        address player = msg.sender;
        
        // Validate input
        require(_side == COIN_SIDE_UP || _side == COIN_SIDE_DOWN, "Invalid bet side");
        
        // Check validity of this game house
        require(gameMaster.isRegisteredGameHouse(address(this)), "Invalid game house");
        
        // Check whether game is ready or not
        require(isGameReady(), "Game is not ready");
        
        // Check _amount is in range of betable values
        (uint256 minBetableValue, uint256 maxBetableValue) = getBetableAmtRange();
        require(_amount >= minBetableValue && _amount <= maxBetableValue, "Bet amount is not allowed");
        
        // Call `onBeforeBet` handle of extensions
        uint256 ttExtensions = totalExtensions();
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onBeforeBet(player, _amount, _side, 0);
        }
        
        paymentCurrency.safeTransferFrom(player, address(this), _amount);
        
        // Lock fund of game house (to guarantee the payment when the player wins this game)
        _lockFundByGame(2 * _amount);
        
        uint56 currentBetId = statsData.currentBetId;
        
        // Call VRF consumer to get a random number
        uint256 vrfRequestId = uint256(vrfConsumer.requestRandomNumber());
        
        // Save mapping between req ID and betId
        betOfRequest[vrfRequestId] = currentBetId;
        
        // Save bet record
        pBetRecords[currentBetId] = BetRecord({
            betSide: _side,
            revealSide: 0,
            state: GAME_STATE_PENDING,
            player: player,
            amount: _amount,
            placedBlock: block.number,
            vrfRequestId: vrfRequestId,
            randomNum: 0
        });
        
       
        // Update game stats
        statsData.betAmt += uint128(_amount / 1e9);
        if(!hadPlayed(player)){
            statsData.uniquePlayers += 1;
            pHadPlayed[player] = true;
        }
        statsData.currentBetId = currentBetId + 1;
        
        // Update player storage
        if(address(playerStorage) != address(0)){
            playerStorage.safeUpdateGameData({
                _tracker: address(tracker),
                _player: player,
                _asNewGame: true,
                _asWinner: false,
                _amountIn: 0,
                _amountOut: _amount,
                _paymentToken: address(paymentCurrency) 
            }); 
        }
        
        // Emit event
        emit BetPlace(currentBetId, vrfRequestId);
        
        // Call `onAfterBet` handle of extensions
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onAfterBet(currentBetId);
        }
        
    }
    
    // Callback by VRF consumer when randomness fulfilled
    // Note that we just record random number and update bet state, but do not resolve the game here
    // (because the game resolving process may have cost > 200K gas, that causes the failed by Chainlink VRF callback)
    function fulfillRandomness(bytes32 _requestId, uint256 _randomNum) external {
        require(msg.sender == address(vrfConsumer), "Only VRF consumer");
        
        uint256 toResolveBetId = betOfRequest[uint256(_requestId)];
        require(toResolveBetId != 0, "Invalid request");
        
        // Verify game state
        require(pBetRecords[toResolveBetId].state == GAME_STATE_PENDING, "Invalid game state");
        
        // Update bet record
        pBetRecords[toResolveBetId].state = GAME_STATE_RANDOMNESS_FULFILLED;
        pBetRecords[toResolveBetId].randomNum = _randomNum;
        
       // Emit event
        emit FulfillRandomness(toResolveBetId);
    }
    
    function finalizeGame(uint56 _betId) external {
        uint56 currentBetId = statsData.currentBetId;
        
        // Check existance of the bet
        require(_betId < currentBetId, "Invalid _betId");
        
        BetRecord storage betRecord = pBetRecords[_betId];
        
        // Verify game state
        require(betRecord.state == GAME_STATE_RANDOMNESS_FULFILLED, "Invalid game state");
        
        uint256 randomNum = betRecord.randomNum;
        
        // Call `onBeforeFinalize` hanndle of extensions
        uint256 ttExtensions = totalExtensions();
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onBeforeFinalize(_betId, randomNum);
        }
        
        uint8 revealSide = uint8((randomNum % 2)) + 1;
        
        // Calculate game fees
        uint256 totalFee = (betRecord.amount * totalFeePerBet()) / MAX_BIPS;
        uint256 operationFee = (betRecord.amount * operationFeePerBet) / MAX_BIPS;
        
        // update bet record
        betRecord.revealSide = revealSide;
        betRecord.state = GAME_STATE_FINALIZED;

        // unlock game house fund
        _releaseFundByGame(2 * betRecord.amount);
        
        // payout if the player wins
        uint256 payoutAmt = 0;
        if(revealSide == betRecord.betSide){
            payoutAmt = 2 * betRecord.amount - totalFee;
            paymentCurrency.safeTransfer(betRecord.player, payoutAmt);
            
             // Update player storage
            if(address(playerStorage) != address(0)){
                playerStorage.safeUpdateGameData({
                    _tracker: address(tracker),
                    _player: betRecord.player,
                    _asNewGame: false,
                    _asWinner: true,
                    _amountIn: payoutAmt,
                    _amountOut: 0,
                    _paymentToken: address(paymentCurrency) 
                });
            }
        }
        
        // Update game stats data
        statsData.finalizedGames += 1;
        if(payoutAmt != 0){
            statsData.payoutAmt += uint128(payoutAmt / 1e9);
        }
        
        // collect operation fee (for Penguin Finance)
        _collectOperationFee(operationFee);

         // collect game house fee
        _collectFee(totalFee - operationFee);
        
        // emit event
        emit FinalizeGame(_betId, payoutAmt, totalFee);
        
        // Call `onAfterFinalize` hanndle of extensions
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onAfterFinalize(_betId, randomNum);
        }
    }
    
    
    // Check whether the player can cancel his game or not
    function isCancelableGame(uint56 _betId) public view returns(bool){
        if(_betId >= statsData.currentBetId){
            // Bet does not exist
            return (false);
        }
        if(pBetRecords[_betId].state != GAME_STATE_PENDING){
            return (false);
        }
        
        return (block.number > pBetRecords[_betId].placedBlock + gameCancelablePassedBlocks);
    }
    
    // For player who wants to recover fund manually if the game is cancelable
    function cancelGame(uint56 _betId) external {
        // Check game is cancelable or not
        require(isCancelableGame(_betId), "Cannot cancel this game");
        
        BetRecord storage betRecord = pBetRecords[_betId];
        
        // Make sure that only the player can cancel this game
        require(betRecord.player == msg.sender, "Only player of this bet");
        
        // Call `onBeforeCancel` handle of extensions
        uint256 ttExtensions = totalExtensions();
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onBeforeCancel(_betId);
        }
        
        // update bet record
        betRecord.state = GAME_STATE_CANCELED;
        
        // Update game stats data
        statsData.canceledGames += 1;
        
         // Update player storage
        if(address(playerStorage) != address(0)){
            playerStorage.safeUpdateGameData({
                _tracker: address(tracker),
                _player: betRecord.player,
                _asNewGame: false,
                _asWinner: false,
                _amountIn: betRecord.amount,
                _amountOut: 0,
                _paymentToken: address(paymentCurrency) 
            });
        }
        
        // unlock game house fund
        _releaseFundByGame(2 * betRecord.amount);
        
        // Refund to player
        paymentCurrency.safeTransfer(betRecord.player, betRecord.amount);
        
        // emit event
        emit CancelGame(_betId);
        
        // Call `onAfterCancel` handle of extensions
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onAfterCancel(_betId);
        }
    }
    
    
    function onMigration(IGameHouse _fromGameHouse) public virtual override onlyGameMaster{
        super.onMigration(_fromGameHouse);
        
        oldGameHouse = ICoinFlipGameHouseV1(address(_fromGameHouse));
        
        // Copy stats data
        (
            statsData.betAmt,
            statsData.payoutAmt,
            statsData.currentBetId,
            ,                               // Ignore nextSetupBetId
            statsData.finalizedGames,
            statsData.canceledGames,
            statsData.uniquePlayers
        ) = oldGameHouse.statsData();
        
        startCurrentBetId = statsData.currentBetId;
        
        // Copy game settings
        minBetAmt = oldGameHouse.minBetAmt();
        maxBetAmt = oldGameHouse.maxBetAmt();
    }
}


contract CoinFlipGameHouseVRFFactory is IGameHouseFactory {
    IVRFConsumer public immutable vrfConsumer;
    
    constructor(IVRFConsumer _vrfConsumer){
        vrfConsumer = _vrfConsumer;
    }
    
    function create(IGameMaster _gameMaster, address _defaultFeeAllocator, address _tracker) 
    external override returns(IGameHouse){
        CoinFlipGameHouseVRF gameHouse = new CoinFlipGameHouseVRF(_gameMaster, _defaultFeeAllocator, _tracker, vrfConsumer);
        // Transfer ownership to sender
        gameHouse.transferOwnership(msg.sender);
        return gameHouse;
    }
}
