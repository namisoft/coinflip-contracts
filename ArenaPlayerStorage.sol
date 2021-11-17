// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "./Commons.sol";

interface ITracker {
    function canTrack(address _target) external view returns(bool);
    function addToTracking(address _target) external;
    function removeFromTracking(address _target) external;
}

/**
 * @title Arena Player Storage interface
 */
interface IArenaPlayerStorage {
    // User profile
    struct Profile {
        uint8 avatarType;                                   // Type of avatar: 1 - use "built-in" avatar, 2 - use NFT avatar
        address avatarNFTContract;                          // NFT contract address in the case of NFT-avatar; otherwise, value = 0x0
        uint256 avatarId;                                   // ID of avatar. In the case of NFT avatar, this is the NFT token ID
        string nickName;                                    // Player nickname
    }
    
    // Game play stats of player for each game house
    struct GamePlayStats {
        // Data slot 1
        uint128 amountOut;          // Total amount out (in GWEI to save gas)
        uint128 amountIn;           // Total amount in (in GWEI to save gas)
        // Data slot 2
        uint64 games;               // Total games that user played
        uint64 wonGames;            // Total games that user won
        uint64 firstTime;           // The first time that user played this game
        uint64 lastTime;            // The last recently time that user played this game
    }
    
    function hadApproved(address _player, address _of) external view returns(bool);
    function approve(address _of) external;
    function unapprove(address _of) external;
    
    function nickName(address _player) external view returns(string memory);
    function avatar(address _player)  external view returns(uint8 _avatarType, uint256 _avatarId, IERC721 _avatarNFTContract);

    function setNickName(string memory _nickName) external;
    function setAvatarBuiltIn(uint256 _avatarId) external;
    function setAvatarNFT(IERC721 _nftContract, uint256 _tokenId) external;
    
    function setNickNameFor(address _player, string memory _nickName) external;
    function setAvatarBuiltInFor(address _player, uint256 _avatarId) external;
    function setAvatarNFTFor(address _player, IERC721 _nftContract, uint256 _tokenId) external;
    
    function hadPlayed(address _player, address _gameHouse) external view returns(bool);
    function playStats(address _player, address _gameHouse) external view 
    returns(
    uint256 _amountOut, 
    uint256 _amountIn,
    uint64 _games, 
    uint64 _wonGames,
    uint64 _firstTime,
    uint64 _lastTime
    );
    
    // Update game data
    function updateGameData(
        address _tracker,
        address _player, 
        bool _asNewGame,
        bool _asWinner,
        uint256 _amountIn,
        uint256 _amountOut
        ) external;
}

/**
 * @title Arena Player Storage implementation
 * @dev Store player info
 */
contract ArenaPlayerStorage is IArenaPlayerStorage {
    uint8 private constant AVATAR_TYPE_BUILT_IN = 1;
    uint8 private constant AVATAR_TYPE_NFT = 2;
    
    // Contracts that has been approved by player: player => (contract => bool).
    // An approved contract can change user profile (nickname, avatar) on behalf of player.
    mapping(address => mapping(address => bool)) public override hadApproved;
    
    mapping(address => Profile) public profile;    // user profile
    
    // flags to know whether profile set or not
    mapping(address => bool) public isNicknameSet;
    mapping(address => bool) public isAvatarSet;
  
    
    // Play stats of a player for a specific game: player => ((game contract) => GamePlayStats)
    mapping(address => mapping(address => GamePlayStats)) private gamePlayStats; 
    
    // Nickname DB
    mapping(string => bool) public existingNickname;
    
    modifier onlyApprovedCaller(address _player) {
        require(hadApproved[_player][msg.sender], "Not a approved caller");
        _;
    }
    
   
    function approve(address _of) external override {
        hadApproved[msg.sender][_of] = true;
    }
    
    function unapprove(address _of) external override {
        hadApproved[msg.sender][_of] = false;
    }
    
    
     function nickName(address _player) external view override returns(string memory){
        return profile[_player].nickName;
    }
    
    
    // Set nick name
    function setNickName(string memory _nickName) external override{
       _setNickname(msg.sender, _nickName);
    }
    
    function setNickNameFor(address _player, string memory _nickName) external override onlyApprovedCaller(msg.sender){
        _setNickname(_player, _nickName);
    }
    

    function avatar(address _player)  
    external 
    view 
    override 
    returns(uint8 _avatarType, uint256 _avatarId, IERC721 _avatarNFTContract)
    {
         Profile storage info = profile[_player];
         (_avatarType, _avatarId, _avatarNFTContract) = 
         (info.avatarType, info.avatarId, IERC721(info.avatarNFTContract));
    }
     
    
    // Set Penguin built-in avatar
    function setAvatarBuiltIn(uint256 _avatarId) external override{
        _setAvatarBuiltIn(msg.sender, _avatarId);
    }
    
    function setAvatarBuiltInFor(address _player, uint256 _avatarId) external override onlyApprovedCaller(msg.sender){
        _setAvatarBuiltIn(_player, _avatarId);
    }
    
    function hadPlayed(address _player, address _gameHouse) external view override returns(bool){
        return (gamePlayStats[_player][_gameHouse].games != 0);
    }
    
    // set NFT avatar
    function setAvatarNFT(IERC721 _nftContract, uint256 _tokenId) external override{
        _setAvatarNFT(msg.sender, _nftContract, _tokenId);
    }
    
    function setAvatarNFTFor(address _player, IERC721 _nftContract, uint256 _tokenId) external override onlyApprovedCaller(msg.sender){
        _setAvatarNFT(_player, _nftContract, _tokenId);
    }
    
    
    function playStats(address _player, address _gameHouse) external view override 
    returns(
    uint256 _amountOut, 
    uint256 _amountIn,
    uint64 _games, 
    uint64 _wonGames,
    uint64 _firstTime,
    uint64 _lastTime
    ){
        GamePlayStats memory stats = gamePlayStats[_player][_gameHouse];
        _amountOut = stats.amountOut * 1e9;
        _amountIn = stats.amountIn * 1e9;
        _games = stats.games;
        _wonGames = stats.wonGames;
        _firstTime = stats.firstTime;
        _lastTime = stats.lastTime;
    }
    
    
    function updateGameData(
        address _tracker,
        address _player, 
        bool _asNewGame,
        bool _asWinner,
        uint256 _amountIn,
        uint256 _amountOut
        ) external override {
            address recordFor;
            if(_tracker == address(0)){
                // record data for `msg.sender` itself
                recordFor = msg.sender;
            } else {
                // we need to check if the `_tracker` is really the tracker of `msg.sender`
                //  (to avoid faker) by calling `canTrack` method of `_tracker` contract.
                // We will use low-level call here to avoid any reverting.
                
                // Dummy variable; allows access to method selector in next line. See
                // https://github.com/ethereum/solidity/issues/3506#issuecomment-553727797
                ITracker dummy;
                bytes memory callData = abi.encodeWithSelector(dummy.canTrack.selector, msg.sender);
                (bool success, bytes memory result) = _tracker.call(callData);
            
                if(!success) {
                    // cannot call method canTrack() of `_tracker` for somehow
                    return;
                }
            
                // decode the call result
                (bool canTrack) = abi.decode(result, (bool));
            
                if(!canTrack) {
                    // `_tracker` is not the tracker of msg.sender
                    return;
                }
                
                // record data for `_tracker`
                recordFor = _tracker;
            }
            
            // update stats data
            
            if(_asNewGame){
                gamePlayStats[_player][recordFor].games += 1;
                if(gamePlayStats[_player][recordFor].firstTime == 0){
                    gamePlayStats[_player][recordFor].firstTime = uint64(block.timestamp);
                }
                gamePlayStats[_player][recordFor].lastTime = uint64(block.timestamp);
            }
            if(_asWinner){
                gamePlayStats[_player][recordFor].wonGames += 1;
            }
            if(_amountIn > 0){
                gamePlayStats[_player][recordFor].amountIn += uint128(_amountIn / 1e9);
            }
            if(_amountOut > 0){
                gamePlayStats[_player][recordFor].amountOut += uint128(_amountOut / 1e9); 
            }

    }
    
    
    function _setNickname(address _player, string memory _nickName) internal{
        require(!existingNickname[_nickName], "Nickname already existed");
        existingNickname[_nickName] = true;
        profile[_player].nickName = _nickName;
        if(!isNicknameSet[_player]){
            isNicknameSet[_player] = true;
        }
    }
    
    function _setAvatarBuiltIn(address _player, uint256 _avatarId) internal{
        profile[_player].avatarType = AVATAR_TYPE_BUILT_IN;
        profile[_player].avatarId = _avatarId;
        if(!isAvatarSet[_player]){
            isAvatarSet[_player] = true;
        }
    }
    
    function _setAvatarNFT(address _player, IERC721 _nftContract, uint256 _tokenId) internal{
        require(_nftContract.ownerOf(_tokenId) == _player, "NFT token is not belong user");
        profile[_player].avatarType = AVATAR_TYPE_NFT;
        profile[_player].avatarNFTContract = address(_nftContract);
        profile[_player].avatarId = _tokenId; 
        if(!isAvatarSet[_player]){
            isAvatarSet[_player] = true;
        }
    }
    
}