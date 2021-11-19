// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "./Commons.sol";
import "./ArenaPlayerStorage.sol";
import "./PenguinRandomizer.sol";

// iPEFI (Nest) interface
interface iPEFI is IERC20 {
    function leave(uint256 share) external;
}

interface IERC20Receiver {
    function onReceive(address _erc20Token, uint256 _amount) external;
}


// Interface for trackable contract.
// A tracker works as an unique ID for the contract; this is useful when
// we migrare the contract to new one but still want to keeping 
// some current references of contract (player stats for example)
interface ITrackable {
    function tracker() external view returns(ITracker);
}


// Interface for game master
interface IGameMaster {
    function owner() external view returns(address);
    function isRegisteredGameHouse(address _toCheck) external view returns(bool);
    function isTrustedParty(address _toCheck) external view returns(bool);
    function onCollectOperationFee(uint256 _amount) external;
}


// Interface for betting game house
interface IGameHouse is ITrackable {
    function owner() external view returns(address);
    function gameMaster() external view returns(IGameMaster);
    function paymentCurrency() external view returns(IERC20);
    function playerStorage() external view returns(IArenaPlayerStorage);
    function randomizer() external view returns(IRandomizer);
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
    function setRandomizer(IRandomizer _randomizer) external;
    function setResolveGameOnRandomnessFulfillment(bool _value) external;
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
    function create(
        ITracker _tracker,
        IGameMaster _gameMaster,  
        IERC20 _paymentCurrency, 
        IArenaPlayerStorage _playerStorage,
        IRandomizer _randomizer,
        address _defaultFeeAllocator
        ) external returns(IGameHouse);
}

// Game extension interface
interface IGameExtension {
    function onInit() external;
    function onDeinit() external;
}

// The abstract contract that defines some common constants
// these are used widely in our contracts
abstract contract PenguinDef {
    uint256 internal constant MAX_BIPS = 10000;
    
    // TODO: PEFI token: please change to the proper value on deployment
    address internal constant PEFI = 0x152C8ACFa8eDE4A39611fA7d84C4485e1C1F3Dd2;
    
    // TODO: iPEFI token: please change to the proper value on deployment
    address internal constant NEST = 0x13bfD9082fb61C04461c47D33Cee9479535bBa4f;
}


contract Tracker is ITracker, Ownable {
    mapping(address => bool) public override canTrack;
    
    function addToTracking(address _target) external override onlyOwner {
        canTrack[_target] = true;
    }
    
    function removeFromTracking(address _target) external override onlyOwner {
        canTrack[_target] = false;
    }
}


/*
 *  Game master contract that is in charge of:
 *   - Managing game randomizer, player storage, operational fee collectors
 *   - Managing game houses (allowing someone to create a "trustless" game house)
 *  Game master can be used in any kind single betting game
 */
contract GameMaster is IGameMaster, PenguinDef, Withdrawable, Ownable {
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    
    // IGameHouseFactory public gameHouseFactory;
    mapping(address => bool) public isTrustedGameHouseFactory;
    
    // Payment currencies supported by this game master
    EnumerableSet.AddressSet private supportedCurrencies;
    
    // in the form (game house factory) => yes/no
    mapping(address => bool) public allowExternalGameHouse;
    
    //uint256 public gameHouseMinInitialFund = 1000 * 1e18;
    
    // required minimum intial fund for game house
    // in the form: (payment currency) => amount
    mapping(address => uint256) minRequiredInitialFund;
    
    EnumerableSet.AddressSet private gameHouseRegistry;
    
    mapping(address => bool) public override isRegisteredGameHouse;
    
    
    // Default player storage that used when create new game house
    IArenaPlayerStorage public playerStorage;
    
    // Default randomizer that used when create new game house
    IPenguinRandomizer public randomizer;
    
    // Default operation fee collected on bet amount (devided by 10,000; so 20 means 0.2%)
    uint256 public defaultOperationFeePerBet = 0;
    
    struct FeeAllocator {
        address target;     // Address that a share portion of fee will be distributed to
        uint256 share;      // Distributed share of fee (devided by 10,000)
    }
    
    // Default operation fee allocators that is set for game house on registration
    FeeAllocator[] public defaultOperationFeeAllocators;
    // Specified operation fee allocators for each game house (can be set by game master owner only)
    // it is in the form: (game house tracker) => FeeAllocator[]
    mapping(address => FeeAllocator[]) public operationFeeAllocators;
    // accumulated operation fee by game house
    // it is in the form: tracker => amount
    mapping(address => uint256) public accumulatedOperationFee;
    
    // indicate "external" trusted contracts that can be called by our contracts
    // (for example: if a fee allocator is set as a trusted contract, its `onReceive` method will
    //  be called on fee collect to do further logic that gives more flexibility for fee distribution model)
    mapping(address => bool) public override isTrustedParty;
    
    
    constructor(
        address _defaultPaymentCurrency, 
        IArenaPlayerStorage _playerStorage, 
        IPenguinRandomizer _randomizer,
        address _defaultFeeAllocator
        )
    Withdrawable(new address[](0)) {
        supportedCurrencies.add(_defaultPaymentCurrency);
        
        setPlayerStorage(_playerStorage, false);
        
        randomizer = _randomizer;
        
        if(_defaultFeeAllocator != address(0)){
            defaultOperationFeeAllocators.push(FeeAllocator({
                target: _defaultFeeAllocator,
                share: MAX_BIPS
            }));
        }
    }
    
    /// Register game house
    function registerGameHouse(
        IGameHouseFactory _factory, 
        IERC20 _paymentCurrency,
        uint256 _initialFund, 
        address _defaultFeeAllocator
    ) 
    external returns(address) {
        address caller = msg.sender;
        if(!allowExternalGameHouse[address(_factory)]){
            require(caller == owner(), "External Game House is not allowed");
        }
        
        uint256 minInitialFund = minRequiredInitialFund[address(_paymentCurrency)];
        if(minInitialFund == 0) {
            // required value is not set yet, we use default value
            minInitialFund = 1000 * 1e18;
        }
        
        require(isTrustedGameHouseFactory[address(_factory)], "Untrusted factory");
        require(isSupportedCurrency(address(_paymentCurrency)), "Unsupported payment token");
        require(_initialFund >= minInitialFund, "Initial deposit fund is not good");
        require(_paymentCurrency.balanceOf(caller) >= _initialFund, "Balance exceeds");
        
        ITracker tracker = new Tracker();
        
        // Create game house contract
        IGameHouse gameHouse = _factory.create({
            _tracker: tracker, 
            _gameMaster: this, 
            _paymentCurrency: _paymentCurrency, 
            _playerStorage: playerStorage, 
            _randomizer: randomizer,
            _defaultFeeAllocator: _defaultFeeAllocator
            
        });
        
        // Let tracker accepting new game house
        tracker.addToTracking(address(gameHouse));
        
        // Add game house to randomizer's trusted consumers list
        randomizer.addConsumer(address(gameHouse));
    
        // Set operational fee per bet
        gameHouse.setOperationFee(defaultOperationFeePerBet);
        // Set operational fee allocators
        uint256 totalAllocators = defaultOperationFeeAllocators.length;
        if(totalAllocators > 0){
            for(uint i=0; i<defaultOperationFeeAllocators.length; i++){
                FeeAllocator memory allocator = defaultOperationFeeAllocators[i];
                operationFeeAllocators[address(gameHouse)].push(allocator);
            }
        }
        
        // Transfer initial fund to this contract
        _paymentCurrency.safeTransferFrom(caller, address(this), _initialFund);
        
        // deposit to game house contract
        _paymentCurrency.approve(address(gameHouse), _initialFund);
        gameHouse.depositFund(_initialFund);
        _paymentCurrency.approve(address(gameHouse), 0);
        
        // Transfer ownership of game house contract to caller account
        gameHouse.transferOwnership(caller);
        
        // Update game house registry
        gameHouseRegistry.add(address(gameHouse));
        isRegisteredGameHouse[address(gameHouse)] = true;
        
        return address(gameHouse);
    }
    
    // Unregister game house
    function unregisterGameHouse(address _gameHouse, address _withdrawFundTo) external{
        require(isRegisteredGameHouse[_gameHouse], "Not in the game house registry");
        
        // only game house owner or Penguin Finance can do this
        require(
            msg.sender == IGameHouse(_gameHouse).owner() || 
            msg.sender == owner(), 
            "Not allowed to perform this action"
        );
        
        isRegisteredGameHouse[_gameHouse] = false;
        gameHouseRegistry.remove(_gameHouse);
         
        // Call onUnReg to deal with locked fund
        
        if(msg.sender == owner()){
            // instruct game house contract to withdraw fund
            IGameHouse(_gameHouse).onUnreg(_withdrawFundTo);
        } else {
            // because in this case, the caller is game master owner but not game house owner,
            // then we do NOT allow withdrawing fund! That means the remaining fund is still in 
            // the game house contract, and game house owner can withdraw it later.
            IGameHouse(_gameHouse).onUnreg(address(0));
        }
    }
    
    // Migrate a game house to new one
    // (only admin or game house owner can call)
    function migrateGameHouse(address _fromGameHouse, IGameHouseFactory _factory) external returns(address) {
        require(isRegisteredGameHouse[_fromGameHouse], "Not in the game house registry");
        require(isTrustedGameHouseFactory[address(_factory)], "Untrusted factory");
        
        IGameHouse fromGameHouse = IGameHouse(_fromGameHouse);
        address gameHouseOwner = fromGameHouse.owner();
        require(
            msg.sender == owner() || 
            msg.sender == gameHouseOwner, 
            "Only owner or Game House ownner"
        );
            
        ITracker tracker = fromGameHouse.tracker();
            
        // Create new game house contract and migrate
        IGameHouse newGameHouse = _factory.create({
            _tracker: tracker,
            _gameMaster: this,
            _paymentCurrency: fromGameHouse.paymentCurrency(), 
            _playerStorage: fromGameHouse.playerStorage(),
            _randomizer: fromGameHouse.randomizer(),
            _defaultFeeAllocator: address(0)
        });
        
        fromGameHouse.migrate(newGameHouse);
        newGameHouse.onMigration(fromGameHouse);
        
        // let tracker accepting new game house
        tracker.addToTracking(address(newGameHouse));
        
        // Transfer ownership of new game house contract to gameHouseOwner
        newGameHouse.transferOwnership(gameHouseOwner);
        
        // remove current game house from the registry
        isRegisteredGameHouse[_fromGameHouse] = false;
        gameHouseRegistry.remove(_fromGameHouse);
        // add new game house to registry
        isRegisteredGameHouse[address(newGameHouse)] = true;
        gameHouseRegistry.add(address(newGameHouse));
        
        return address(newGameHouse);
    }
    
    
    function onCollectOperationFee(uint256 _amount) external override{
        if(isRegisteredGameHouse[msg.sender] && _amount > 0){
            address tracker = address(IGameHouse(msg.sender).tracker());
            IERC20 paymentCurrency = IGameHouse(msg.sender).paymentCurrency();
            accumulatedOperationFee[tracker] += _amount;
            FeeAllocator[] memory feeAllocators = operationFeeAllocators[tracker];   
            for(uint i=0; i<feeAllocators.length; i++){
                uint256 amtToDistribute = (_amount * feeAllocators[i].share) / MAX_BIPS;
                address target = feeAllocators[i].target;
                if(address(paymentCurrency) == NEST && target == NEST){
                    _sendToNest(_amount);
                }else{
                    _safeTokenTransfer(address(paymentCurrency), amtToDistribute, target);  
                    // if the allocator immplements IERC20Receiver interface, we will call its `onReceive` method.
                    // We use low-level call here to avoid any exception from callee that may cause reverting
                    
                    // Dummy variable; allows access to method selector in next line. See
                    // https://github.com/ethereum/solidity/issues/3506#issuecomment-553727797
                    IERC20Receiver dummy;
                    bytes memory callData = abi.encodeWithSelector(dummy.onReceive.selector, address(paymentCurrency), amtToDistribute);
                    (bool success,) = target.call(callData);
                    // Avoid unused-local-variable warning. (success is only present to prevent
                    // a warning that the return value of target.call is unused.)
                    (success);
                }
            }
        }
    }
    
    function setPlayerStorage(IArenaPlayerStorage _newPlayerStorage, bool _updateToGameHouses) public onlyOwner {
        if(_updateToGameHouses){
            for(uint256 i=0; i<gameHouseRegistry.length(); i++){
                IGameHouse(gameHouseRegistry.at(i)).setPlayerStorage(_newPlayerStorage);
            }
        }
        playerStorage = _newPlayerStorage;
    }
    
    function setPlayerStorageForGameHouse(IGameHouse _gameHouse, IArenaPlayerStorage _newPlayerStorage) external onlyOwner{
        require(isRegisteredGameHouse[address(_gameHouse)], "Not in the game house registry");
        _gameHouse.setPlayerStorage(_newPlayerStorage);
    }
    
    function setRandomizer(IPenguinRandomizer _newRandomizer, bool _updateToGameHouses) public onlyOwner {
        if(_updateToGameHouses){
            for(uint256 i=0; i<gameHouseRegistry.length(); i++){
                address gameHouse = gameHouseRegistry.at(i);
                IGameHouse(gameHouse).setRandomizer(_newRandomizer);
                _newRandomizer.addConsumer(address(gameHouse));
            }
        }
        randomizer = _newRandomizer;
    }
    
    // to call this method, this game master contract must be granted CONSUMER_ADMIN_ROLE role in `_randomizer`
    function setRandomizerForGameHouse(IGameHouse _gameHouse, IPenguinRandomizer _randomizer) external onlyOwner{
        require(isRegisteredGameHouse[address(_gameHouse)], "Not in the game house registry");
        _gameHouse.setRandomizer(_randomizer);
        _randomizer.addConsumer(address(_gameHouse));
    }
    
    // to call this method, this game master contract must be granted CONSUMER_ADMIN_ROLE role in `_randomizer`
    function removeConsumerFromRandomizer(IPenguinRandomizer _fromRandomizer, IGameHouse _toRemoveConsumer) external onlyOwner {
        _fromRandomizer.removeConsumer(address(_toRemoveConsumer));
    }
    
    // Disable using tracker of a game house manually
    // (after this operation, the game house will be not able to update player storage anymore)
    function removeGameHouseFromTracking(IGameHouse _gameHouse) external onlyOwner {
        _gameHouse.tracker().removeFromTracking(address(_gameHouse));
    }
    
    function registerGameHouseFactory(address _factory, bool _allowExternalHouse) external onlyOwner {
        require(_factory.isContract(), "Not a contract");
        isTrustedGameHouseFactory[_factory] = true;
        allowExternalGameHouse[_factory] = _allowExternalHouse;
    }
    
    function removeGameHouseFactory(address _factory) external onlyOwner {
        isTrustedGameHouseFactory[_factory] = false;
    }
    
    function setAllowExternalGameHouse(address _factory, bool _allowExternalHouse) external onlyOwner {
        require(isTrustedGameHouseFactory[_factory], "Not a trusted factory");
        allowExternalGameHouse[_factory] = _allowExternalHouse;
    }
    
  
    function setDefaultOperationFee(uint256 _value) public onlyOwner {
        require(_value <= MAX_BIPS, "Value exceeded");
        defaultOperationFeePerBet = _value;
    }
    
    function setOperationFee(IGameHouse _forGameHouse, uint256 _value) public onlyOwner {
        require(isRegisteredGameHouse[address(_forGameHouse)], "Unregistered game house");
        _forGameHouse.setOperationFee(_value);
    }
    
    // warning: call this method will replace all current default operation fee allocators
    function setDefaultOperationFeeAllocators(address[] memory _targets, uint256[] memory _shares) external onlyOwner{
        uint256 numAllocators = _targets.length;
        require(numAllocators > 0, "At least 1 allocator required");
        require(numAllocators == _shares.length, "Invalid input: arrays length mismatched");
        
        uint256 totalShares;
        for(uint i=0; i<numAllocators; i++){
            totalShares += _shares[i];
        }
        require(totalShares != MAX_BIPS, "Invalid total shares");
        
        if(defaultOperationFeeAllocators.length > 0){
            // clear out current allocators list
             delete defaultOperationFeeAllocators;   
        }
        
        for(uint i=0; i<numAllocators; i++){
            defaultOperationFeeAllocators.push(FeeAllocator({
                target: _targets[i],
                share: _shares[i]
            }));
        }
        
    }
    
     // warning: call this method will replace all current operation fee allocators of target game houses
    function setOperationFeeAllocators(IGameHouse[] memory _forGameHouses, address[] memory _targets, uint256[] memory _shares) 
    external onlyOwner {
            uint256 numAllocators = _targets.length;
            require(numAllocators > 0, "At least 1 allocator required");
            require(numAllocators == _shares.length, "Invalid input: arrays length mismatched");
        
            uint256 totalShares;
            for(uint i=0; i<numAllocators; i++){
                totalShares += _shares[i];
            }
            require(totalShares != MAX_BIPS, "Invalid total shares");
            
            uint256 numGameHouses = _forGameHouses.length;
            for(uint256 i=0; i<numGameHouses; i++){
                if(isRegisteredGameHouse[address(_forGameHouses[i])]){
                    address gameHouseTracker = address(_forGameHouses[i].tracker());
                    if(operationFeeAllocators[gameHouseTracker].length > 0){
                        delete operationFeeAllocators[gameHouseTracker];
                    }
                    for(uint256 j=0; j<numAllocators; j++){
                        operationFeeAllocators[gameHouseTracker].push(FeeAllocator({
                            target: _targets[j],
                            share: _shares[j]
                        }));
                    }
                }
            }
    }
    
    function setMinRequiredInitialFund(address _paymentCurrency, uint256 _amount) external onlyOwner {
        require(_amount > 0, "Bad input");
        minRequiredInitialFund[_paymentCurrency] = _amount;
    }
    
    function gameHousesOf(address _gameOwner) external view returns(address[] memory _gameHouses){
        uint256 ttGameHouses = gameHouseRegistry.length();
        address[] memory temp = new address[](ttGameHouses);
        uint256 count;
        for(uint256 i=0; i<ttGameHouses; i++){
            address gameHouse = gameHouseRegistry.at(i);
            if(IGameHouse(gameHouse).owner() == _gameOwner){
                temp[count] = gameHouse;
                count += 1;
            }
        }
        
        _gameHouses = new address[](count);
        for(uint256 i=0; i<count; i++){
           _gameHouses[i] = temp[i]; 
        }
    }
    
    function totalGameHouses() external view returns(uint256){
        return gameHouseRegistry.length();
    }
    
    function gameHouseAt(uint256 _index) external view returns(IGameHouse){
        return IGameHouse(gameHouseRegistry.at(_index));
    }
    
    function isSupportedCurrency(address _token) public view returns(bool) {
        return supportedCurrencies.contains(_token);
    }
    
    function totalSupportedCurrencies() external view returns(uint256) {
        return supportedCurrencies.length();
    }
    
    function supportedCurrencyAt(uint256 _index) external view returns(address) {
        return supportedCurrencies.at(_index);
    }
    
    function addTrustedParty(address _toAdd) external onlyOwner {
        isTrustedParty[_toAdd] = true;
    }
    
    function removeTrustedParty(address _toRemove) external onlyOwner {
        isTrustedParty[_toRemove] = false;
    }
    
    function setResolveGameOnRandomnessFulfillment(IGameHouse _forGameHouse, bool _value) external onlyOwner {
        require(isRegisteredGameHouse[address(_forGameHouse)], "Not in the game house registry");
        _forGameHouse.setResolveGameOnRandomnessFulfillment(_value);
    }
    
    function addGameExtension(IGameHouse _gameHouse, IGameExtension _ex) external onlyOwner{
        require(isRegisteredGameHouse[address(_gameHouse)], "Not in the game house registry");
        _gameHouse.addExtension(_ex);
        // allow extension using the game house tracker?
        _gameHouse.tracker().addToTracking(address(_ex));
    }
    
    function removeGameExtension(IGameHouse _gameHouse, IGameExtension _ex) external onlyOwner{
        require(isRegisteredGameHouse[address(_gameHouse)], "Not in the game house registry");
        _gameHouse.removeExtension(_ex);
         // remove from tracker
        _gameHouse.tracker().removeFromTracking(address(_ex));
    }
    
    // Used in the case we upgrade this game master contract
    function migrate(IGameMaster _newGameMaster) external onlyOwner {
        for(uint256 i=0; i<gameHouseRegistry.length(); i++){
            IGameHouse(gameHouseRegistry.at(i)).transferGameMaster(_newGameMaster);
        }
    }
    
    function owner() public view virtual override(Ownable, IGameMaster) returns (address) {
        return Ownable.owner();
    }
    
    function withdraw(address _token, uint256 _amount, address _to) external onlyOwner {
        _safeTokenTransfer(_token, _amount, _to);
    }
    
        // Send iPEFI to NEST
    function _sendToNest(uint256 _amount) internal{
        uint256 pefiBalBefore = IERC20(PEFI).balanceOf(address(this));
        iPEFI(NEST).leave(_amount);
        uint256 pefiToSend = IERC20(PEFI).balanceOf(address(this)) - pefiBalBefore;
        IERC20(PEFI).safeTransfer(NEST, pefiToSend);
    }
}


/*
 *  Base class for any single betting game house contract.
 *  This contract does not deal with any game logic; it just deals only with game house fund management
 */
abstract contract GameHouseBase is IGameHouse, PenguinDef, Ownable, AccessControl {
    using SafeERC20 for IERC20;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    
    bytes32 public constant GAME_OPERATION_ROLE = keccak256("GAME_OPERATION_ROLE"); 
    
    // Game master that controls trusted dealers
    IGameMaster public override gameMaster;
    
    // Tracker
    ITracker public immutable override tracker;
    
    // Payment token (ERC20) for game
    IERC20 public immutable override paymentCurrency;
    
    // Player storage
    IArenaPlayerStorage public override playerStorage;
    
    // Randomizer
    IRandomizer public override randomizer;
    
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
    
    constructor(
        ITracker _tracker, 
        IGameMaster _gameMaster, 
        IERC20 _paymentCurrency, 
        IArenaPlayerStorage _playerStorage,
        IRandomizer _randomizer,
        address _defaultFeeAllocator
        ){
        
        tracker = _tracker;
        
        gameMaster = _gameMaster;
        
        paymentCurrency = _paymentCurrency;
        
        playerStorage = _playerStorage;
        
        randomizer = _randomizer;
        
        if(_defaultFeeAllocator != address(0)){
            feeAllocators.push(FeeAllocator({
                target: _defaultFeeAllocator,
                share: MAX_BIPS
            }));
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
        if(gameMaster.isRegisteredGameHouse(address(this))){
            // this is the regular case when the game is still working normally.
            // --> allow to withdraw only unlocked fund
            return (paymentCurrency.balanceOf(address(this)) - totalLockedFund);
        } else {
            // this is the special case when game has already been un-registered from game master.
            // --> allow to withdraw whole fund EXCEPT the amount locked by pending (unresolved) games
            return (paymentCurrency.balanceOf(address(this)) - fundLockedByGames);
        }        
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
        // stop the game itself
        isRunning = false;
        
        if(_withdrawTo != address(0)){
            // Release all fund EXCEPT fund locked by game currently
            uint256 fundToRelease = paymentCurrency.balanceOf(address(this)) - fundLockedByGames;
            if(fundToRelease > 0){
                totalLockedFund = fundLockedByGames;
                paymentCurrency.safeTransfer(_withdrawTo, fundToRelease);
            }
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
    
    function setRandomizer(IRandomizer _randomizer) external onlyGameMaster{
        require(address(_randomizer).isContract(), "Must be contract");
        randomizer = _randomizer; 
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
                // distribute to the NEST directly
                _sendToNest(amtToDistribute);
            }else{
                paymentCurrency.safeTransfer(target, amtToDistribute);
                // if `target` is a trusted contract, we will do futher process
                if(gameMaster.isTrustedParty(target)){
                    // if the allocator immplements IERC20Receiver interface, we will call its `onReceive` method.
                    // We use low-level call here to avoid any exception from callee that may cause reverting.
                    
                    // Dummy variable; allows access to method selector in next line. See
                    // https://github.com/ethereum/solidity/issues/3506#issuecomment-553727797
                    IERC20Receiver dummy;
                    bytes memory callData = abi.encodeWithSelector(dummy.onReceive.selector, address(paymentCurrency), amtToDistribute);
                    (bool success,) = target.call(callData);
                    // Avoid unused-local-variable warning. (success is only present to prevent
                    // a warning that the return value of target.call is unused.)
                    (success);                    
                }
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
        uint256 pefiBalBefore = IERC20(PEFI).balanceOf(address(this));
        iPEFI(NEST).leave(_amount);
        uint256 pefiToSend = IERC20(PEFI).balanceOf(address(this)) - pefiBalBefore;
        IERC20(PEFI).safeTransfer(NEST, pefiToSend);
    }
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


/**
 * @title Arena Coin Flip mini-game implementation
 * @dev Implement gameplay logic of Arena Coin Flip mini-game
 */
contract CoinFlipGameHouse is GameHouseBase, IRandomnessConsumer {
    using SafeERC20 for IERC20;
    
    uint8 internal constant COIN_SIDE_UP = 1;
    uint8 internal constant COIN_SIDE_DOWN = 2;
    
    uint8 internal constant GAME_STATE_PENDING = 1;
    uint8 internal constant GAME_STATE_RANDOMNESS_FULFILLED = 2;
    uint8 internal constant GAME_STATE_FINALIZED = 0x80;
    uint8 internal constant GAME_STATE_CANCELED = 0xff;

    // Min betable amount
    uint256 public minBetAmt = 1e18;
    // Max betable amount
    uint256 public maxBetAmt = 1000 * 1e18;
    
    // Stats data structure (try to "pack" data for saving data storage slot)
    struct StatsData {
        // -- Data slot 1
        uint128 betAmt;         // Total bet amount (in GWEI to save gas)
        uint128 payoutAmt;      // Total payout amount (in GWEI to save gas)
        
        // -- Data slot 2
        uint56 currentBetId;    // Current bet ID. Starting at 1, increase by 1 after each bet placed
        uint56 finalizedGames;
        uint56 canceledGames;
        uint32 uniquePlayers;
    }
    
    // Stats data of this game
    StatsData public statsData;
    
    // Indicate that user had ever played the game or not
    mapping(address => bool) public hadPlayed;
    
    // Bet record data structure
    struct BetRecord {
        uint8 betSide;              // Bet side: 1 - up, 2 - down
        uint8 resolvedSide;         // Resolved side: 1 - up, 2 - down
        uint8 state;                // Game state: 1-pending, 0x80-finalized, 0xFF-canceled
        address player;             // Player address
        uint64 placedBlock;         // Block number where the bet was placed
        
        uint256 amount;             // Bet amount
        uint256 rReqId;             // Randomness request id
        uint256 randomNum;          // Random number that is used to decide the game
    }
    
    // Bet records in the form: betId => BetRecord
    mapping(uint256 => BetRecord) public betRecords;
    
    // mapping: randomness reqId => betId
    mapping(uint256 => uint56) public betIdOfRandomnessReq;
    
    // the flag that indicates if we will resolve the game on receiving the randomness.
    // When switching from our in-house randomizer to Chainlink VRF, we need to set it to `false`
    // (because Chainlink VRF does not allow a callback with more than 200K gas-consuming,
    // that is not enough for our game resolving routine, we need to postpone 
    // this task for bot to process it in a separate TX)
    bool public resolveGameOnRandomnessFulfillment = true;
    
    // The number of blocks (that passed from bet-placed block) 
    // that allows user to cancel the game (if it has not been resolved)
    uint256 public passedBlocksForCancelable = 257;
    
    // Events
    event BetPlace(uint256 indexed betId, uint256 amount, uint8 side, uint256 r, uint256 time);
    event FulfillRandomness(uint256 indexed betId);
    event FinalizeGame(uint256 indexed betId, uint256 payoutAmt, uint256 totalFee);
    event CancelGame(uint256 indexed betId);
   
    
    constructor(
        ITracker _tracker,
        IGameMaster _gameMaster, 
        IERC20 _paymentCurrency,
        IArenaPlayerStorage _playerStorage,
        IRandomizer _randomizer,
        address _defaultFeeAllocator
        ) 
        GameHouseBase(_tracker, _gameMaster, _paymentCurrency, _playerStorage, _randomizer, _defaultFeeAllocator){
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
    
    // Check whether the game is ready or not
    function isGameReady() public view returns(bool){
        return (isRunning && randomizer.isReady());
    }
    
    
    // Get the min/max bet amount that player can place at the moment
    // (front-end can call this function to limit bet values on UI)
    function getBetableAmtRange() public view returns(uint256 _minValue, uint256 _maxValue){
        if(!isGameReady()){
            return (0, 0);
        }
        
        uint256 availableFundToLockByGames = _availableFundToLockByGames();
        
        if(availableFundToLockByGames < minBetAmt){
            // Bet is not allowed
            _minValue = 0;
            _maxValue = 0;
        } else if(availableFundToLockByGames < maxBetAmt){
            _minValue = minBetAmt;
            _maxValue = availableFundToLockByGames;
        } else{
            _minValue = minBetAmt;
            _maxValue = maxBetAmt;
        }
        
    }
    
    // Player calls this function to place the bet
    // @ _side: 1 - UP side, 2 - DOWN side
    function placeBet(uint256 _amount, uint8 _side, uint256 _r) external {
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
        
        // Because we cannot declare too much local vars (that will cause the error in compiling),
        // we define a `tmp` var here for multi-purposes use!
         uint256 tmp;
        
        // Call `onBeforeBet` handle of extensions
        for(tmp=0; tmp<totalExtensions(); tmp++){
            ICoinFlipGameExtension(address(extensionAt(tmp))).onBeforeBet(player, _amount, _side, _r);
        }
        
        paymentCurrency.safeTransferFrom(player, address(this), _amount);
        
        // Lock fund of game house (to guarantee the payment when the player wins this game)
        _lockFundByGame(2 * _amount);
        
        uint56 currentBetId = statsData.currentBetId;
        
        // Call randomizer to get a random number
        bytes memory rInput = new bytes(32);
        assembly { mstore(add(rInput, 32), _r) }
        tmp= randomizer.requestRandomNumber(rInput);
        require(tmp > 0, "Randomizer not ready");
        
        // Save mapping between req ID and betId
        betIdOfRandomnessReq[tmp] = currentBetId;
        
        // Save bet record
        betRecords[currentBetId].betSide = _side;
        betRecords[currentBetId].state = GAME_STATE_PENDING;
        betRecords[currentBetId].player = player;
        betRecords[currentBetId].placedBlock = uint64(block.number);
        betRecords[currentBetId].amount = _amount;
        betRecords[currentBetId].rReqId = tmp;
        /*betRecords[currentBetId] = BetRecord({
            betSide: _side,
            resolvedSide: 0,
            state: GAME_STATE_PENDING,
            player: player,
            time: uint64(block.timestamp),
            amount: _amount,
            rReqId: tmp,
            randomNum: 0
        });*/
        
       
        // Update game stats
        statsData.betAmt += uint128(_amount / 1e9);
        if(!hadPlayed[player]){
            statsData.uniquePlayers += 1;
            hadPlayed[player] = true;
        }
        statsData.currentBetId = currentBetId + 1;
        
        // Update player storage
        if(address(playerStorage) != address(0)){
            playerStorage.updateGameData({
                _tracker: address(tracker),
                _player: player,
                _asNewGame: true,
                _asWinner: false,
                _amountIn: 0,
                _amountOut: _amount
            });
        }
        
        // Emit event
        emit BetPlace(currentBetId, _amount, _side, _r, block.timestamp);
        
        // Call `onAfterBet` handle of extensions
        for(tmp=0; tmp<totalExtensions(); tmp++){
            ICoinFlipGameExtension(address(extensionAt(tmp))).onAfterBet(currentBetId);
        }
    }
    
    
    // Called-back by VRF consumer when randomness fulfilled
    function fulfillRandomness(uint256 _requestId, uint256 _randomNum) external {
        require(msg.sender == address(randomizer), "Only randomizer");
        
        uint56 toResolveBetId = betIdOfRandomnessReq[uint256(_requestId)];
        require(toResolveBetId != 0, "Invalid request");
        
        // Ignore if game state is not 'pending'
        if(betRecords[toResolveBetId].state != GAME_STATE_PENDING){
            // silent quit, not reverting
            return;
        }
        
        // store random number
        betRecords[toResolveBetId].randomNum = _randomNum;
        
        if(resolveGameOnRandomnessFulfillment){
            // resolve the game immediately
            if(_randomNum == 0){
                // cannot generate a randomness: cancel the game
                _cancelGame(toResolveBetId, false);
            } else {
                // finalize the game
                _finalizeGame(toResolveBetId);
            }
        } else {
            // postpone the game resolving
            //  -- Update bet record state
            betRecords[toResolveBetId].state = GAME_STATE_RANDOMNESS_FULFILLED;
            // --- Emit event
            emit FulfillRandomness(toResolveBetId);
        }
    }
    
    function resolveGame(uint56 _betId) external {
        // only allow when the flag resolveGameOnRandomnessFulfillment is off
        require(resolveGameOnRandomnessFulfillment == false, "Not allowed");
        
        // Check existance of the bet
        require(_betId < statsData.currentBetId, "Invalid _betId");
        
        // Verify game state
        require(betRecords[_betId].state == GAME_STATE_RANDOMNESS_FULFILLED, "Invalid game state");
        
        if(betRecords[_betId].randomNum == 0){
            // could not generate a randomness before: cancel the game
            _cancelGame(_betId, msg.sender == betRecords[_betId].player);
        } else {
            // finalize the game
            _finalizeGame(_betId);
        }
    }
    
    
    // Check whether the player can cancel his game or not
    function isCancelableGame(uint56 _betId) public view returns(bool){
        if(_betId >= statsData.currentBetId){
            // Bet does not exist
            return (false);
        }
        
        uint8 state = betRecords[_betId].state;
        
        if(state == GAME_STATE_RANDOMNESS_FULFILLED && betRecords[_betId].randomNum != 0){
            // cannot cancel the game when the randomness already fulfilled
            return (false);
        }
        
        if(state == GAME_STATE_FINALIZED || state == GAME_STATE_CANCELED){
            // Game already resolved
            return (false);
        }
        
        // is cancelable if currrent block is too far from bet palced block
         return (block.number > betRecords[_betId].placedBlock + passedBlocksForCancelable);
    }
    
    // For player who wants to recover fund manually if the game cannot be finalized
    function cancelGame(uint56 _betId) external {
        // Check game is cancelable or not
        require(isCancelableGame(_betId), "Cannot cancel this game");
        // Make sure that only the player can cancel this game
        require(betRecords[_betId].player == msg.sender, "Only player of this bet can cancel it");
        
        _cancelGame(_betId, true);
    }
    
    function setPassedBlocksForCancelable(uint256 _newValue) external onlyOwner {
        passedBlocksForCancelable = _newValue;
    }
    
    function setResolveGameOnRandomnessFulfillment(bool _value) external onlyGameMaster {
        resolveGameOnRandomnessFulfillment = _value;
    }
    
    
    function _finalizeGame(uint56 _betId) internal{
        BetRecord storage betRecord = betRecords[_betId];
         
        uint256 randomNum = betRecord.randomNum;
        
        // Call `onBeforeFinalize` hanndle of extensions
        uint256 ttExtensions = totalExtensions();
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onBeforeFinalize(_betId, randomNum);
        }
        
        // Decide the game
        uint8 resolvedSide = uint8((randomNum % 2)) + 1;
        
        // Calculate game fees
        uint256 totalFee = (betRecord.amount * totalFeePerBet()) / MAX_BIPS;
        uint256 operationFee = (betRecord.amount * operationFeePerBet) / MAX_BIPS;
        
        // update bet record
        betRecord.resolvedSide = resolvedSide;
        betRecord.state = GAME_STATE_FINALIZED;

        // unlock game house fund
        _releaseFundByGame(2 * betRecord.amount);
        
        // payout if the player wins
        uint256 payoutAmt = 0;
        if(resolvedSide == betRecord.betSide){
            payoutAmt = 2 * betRecord.amount - totalFee;
            paymentCurrency.safeTransfer(betRecord.player, payoutAmt);
            
             // Update player storage
            if(address(playerStorage) != address(0)){
                playerStorage.updateGameData({
                    _tracker: address(tracker),
                    _player: betRecord.player,
                    _asNewGame: false,
                    _asWinner: true,
                    _amountIn: payoutAmt,
                    _amountOut: 0
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
            ICoinFlipGameExtension(address(extensionAt(i))).onAfterFinalize(_betId, betRecord.randomNum);
        }
    }
    
    function _cancelGame(uint56 _betId, bool _canceledByPlayer) internal{
        // Call `onBeforeCancel` handle of extensions
        uint256 ttExtensions = totalExtensions();
        for(uint256 i=0; i<ttExtensions; i++){
            ICoinFlipGameExtension(address(extensionAt(i))).onBeforeCancel(_betId, _canceledByPlayer);
        }
        
        BetRecord storage betRecord = betRecords[_betId];
        
        // update bet record
        betRecord.state = GAME_STATE_CANCELED;
        
        // Update game stats data
        statsData.canceledGames += 1;
        
         // Update player storage
        if(address(playerStorage) != address(0)){
            playerStorage.updateGameData({
                _tracker: address(tracker),
                _player: betRecord.player,
                _asNewGame: false,
                _asWinner: false,
                _amountIn: betRecord.amount,
                _amountOut: 0
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
            ICoinFlipGameExtension(address(extensionAt(i))).onAfterCancel(_betId, _canceledByPlayer);
        }
    }
}


// Factory class that supports to create a CoinFlipGameHouse contract instance
contract CoinFlipGameHouseFactory is IGameHouseFactory {
    function create(
        ITracker _tracker,
        IGameMaster _gameMaster,  
        IERC20 _paymentCurrency, 
        IArenaPlayerStorage _playerStorage,
        IRandomizer _randomizer,
        address _defaultFeeAllocator) 
    external override returns(IGameHouse){
        CoinFlipGameHouse gameHouse = new CoinFlipGameHouse(
            _tracker, _gameMaster, _paymentCurrency, _playerStorage, _randomizer, _defaultFeeAllocator
            );
        // Transfer ownership to sender
        gameHouse.transferOwnership(msg.sender);
        return gameHouse;
    }
}