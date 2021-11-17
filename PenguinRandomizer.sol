// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "./Commons.sol";

// Randomizer interface
interface IRandomizer {
    function isReady() external view returns(bool);
    function requestRandomNumber(bytes calldata _input) external returns(uint256);
    // return value: 0- invalid, 1 - ongoing, 2 - finished, 3 -> 255 - errors (depending the contract implementation)
    function checkRequestState(uint256 _requestId) external view returns(uint8);
}


// Randomness consumer interface
interface IRandomnessConsumer {
    function fulfillRandomness(uint256 _requestId, uint256 _randomNum) external;
}

// Abstract contract that implements Commit/Reveal pattern to provide randomness
abstract contract CommitRevealRandomizer is IRandomizer {
    using EnumerableSet for EnumerableSet.UintSet;

    // secret hashes committed but not used
    EnumerableSet.UintSet private usableSecretHashes;
    
    // indicate that secret hash already committed or not: secret hash => true/false
    mapping(uint256 => bool) public isCommittedHash;
    
    // revealed secrets: hash => secret
    mapping(uint256 => uint256) public revealedSecrets;
    
    // the counter for requests
    uint256 public requestCounter;
    
    // randomnness request data record
    struct Request {
        uint256 r;                  // input random number from user
        uint256 blockNum;           // block number where request received
        address consumer;           // consumer who sent the request
        uint256 result;             // generated randomnness
    }
    // mapping: requestId => Request
    mapping(uint256 => Request) public requests;
    
    // mapping: requestId => secret hash
    mapping(uint256 => uint256) public secretAssignedToReq;
    
    // mapping: secret hash => requestId
    mapping(uint256 => uint256) public reqThatSecretAssignedTo;
    
    // Events definition
    event SecretHashCommitted(uint256 indexed secretHash, address indexed committer);
    event SecretHashAssigned(uint256 indexed secretHash, uint256 secretIndex);
    event SecretRevealed(uint256 indexed hash, uint256 secret);
    event FulfillRandomness(uint256 indexed requestId, uint256 randomNum);
    
  
    function totalUsableHashes() external view returns(uint256) {
        return usableSecretHashes.length();
    }
    
    function usableHashAt(uint256 _index) external view returns(uint256) {
        return usableSecretHashes.at(_index);
    }
    
    function isUsableHash(uint256 _value) external view returns(bool) {
        return usableSecretHashes.contains(_value);
    }
    
    function isReady() external view override returns(bool){
        return (usableSecretHashes.length() > 0);
    }
    
    function checkRequestState(uint256 _requestId) external view override returns(uint8){
        uint256 reqBlockNum = requests[_requestId].blockNum;
        if(reqBlockNum == 0){
            // Invalid request
            return 0;
        }
        if(revealedSecrets[secretAssignedToReq[_requestId]] != 0){
            // already finished (secret already revealed)
            return 2;
        }
        if (block.number > reqBlockNum + 257){
            // too far to generate randomness: request will failed (callback with randomNum=0)
            return 3;
        }
        
        // other case: ongoing
        return 1;
    }
    
    function requestRandomNumber(bytes memory _input) external virtual override returns(uint256);
    
    function commit(uint256[] memory _secretHashes) external virtual;
    
    function reveal(uint256 _hash, uint256 _secret) external virtual;
    
    // Consumer calls this function to request a random number.
    // The function will return a request id that should be managed by consumer by somehow.
    // Later, when random number is generated, callback function `fulfillRandomness`of consumer will
    // be invoked to return random number along with request id
    // Rturns `0` means randomizer is not ready or unavailable
    function _requestRandomNumber(bytes memory _input) internal virtual returns(uint256){
        if(usableSecretHashes.length() == 0){
            // no secret hash available
            return 0;
        }
        
        requestCounter += 1;
        
        uint256 requestId = uint256(keccak256(abi.encode(address(this), msg.sender, requestCounter)));
        
        // decode input data
        require(_input.length >= 32, "Invalid _input");
        uint256 r;
        assembly {
            r := mload(add(add(_input, 0x20), 0))
        }
        
        uint256 usedSecretHash = usableSecretHashes.at(0);
        usableSecretHashes.remove(usedSecretHash);
        
        // store the request
        requests[requestId].r = r;
        requests[requestId].blockNum = block.number;
        requests[requestId].consumer = msg.sender;
        
        secretAssignedToReq[requestId] = usedSecretHash;
        
        reqThatSecretAssignedTo[usedSecretHash] = requestId;
        
        // emit event
        emit SecretHashAssigned(usedSecretHash, requestCounter);
        
        return requestId;
    }
    
    // Commit a bunch of secret hashes
    function _commit(uint256[] memory _secretHashes) internal {
        uint len = _secretHashes.length;
        for(uint i=0; i<len; i++){
            if(!isCommittedHash[_secretHashes[i]]){
                usableSecretHashes.add(_secretHashes[i]);
                isCommittedHash[_secretHashes[i]] = true;
                emit SecretHashCommitted(_secretHashes[i], msg.sender);
            }
        }
        
    }
    
    // Reveal a secret
    function _reveal(uint256 _hash, uint256 _secret) internal {
        require(isCommittedHash[_hash], "Unknown secret hash");
        require(revealedSecrets[_hash] == 0, "Already revealed");
        require(_hash == uint256(keccak256(abi.encodePacked(_secret))), "Wrong secret");
        
        revealedSecrets[_hash] = _secret;
        
        usableSecretHashes.remove(_hash);
        
        emit SecretRevealed(_hash, _secret);
        
        uint256 requestId = reqThatSecretAssignedTo[_hash];
        
        if(requestId == 0){
            // no request associated with secret
            return;
        }
        
        // The revealed secret has an associated request --------------------------------
        
        Request memory req = requests[requestId];
        
        if(block.number < req.blockNum + 2){
            // not enough blocks for confirmation; because secret already revealed above, 
            // we must treat as a failed case
            _invokeFulfillRandomness(req.consumer, requestId, 0);
        } else if(block.number > req.blockNum + 257){
            // too far to get hash of block `req.blockNum + 1`
            //  we must also treat as a failed case
             _invokeFulfillRandomness(req.consumer, requestId, 0);
        } else {
            // Generate random number
            bytes32 usedBlockHash = blockhash(req.blockNum + 1);
            uint256 randomNum = uint256(keccak256(abi.encodePacked(_secret, req.r, usedBlockHash)));
            // update request result
            requests[requestId].result = randomNum;
            // callback to consumer
            _invokeFulfillRandomness(req.consumer, requestId, randomNum);
        }
    }
    
    function _invokeFulfillRandomness(address _consumer, uint256 _requestId, uint256 _randomNum) internal {
        emit FulfillRandomness(_requestId, _randomNum);
        // TODO: check gas limit of callback function (how to?)
        IRandomnessConsumer(_consumer).fulfillRandomness(_requestId, _randomNum);
    }
    
    
    // derived contract must override this method to define gas limit of callback function
    function _callbackGasLimit() internal virtual view returns(uint256){
        return 0;
    }
}


// Penguin randomizer interface that restricts randomness requests to trusted consumers only 
interface IPenguinRandomizer is IRandomizer {
    // add trusted consumer
    function addConsumer(address _consumer) external;
    // remove consumer from trusted list
    function removeConsumer(address _consumer) external;
}


// Penguin Randomizer contract (derived from CommitRevealRandomizer base contract)
// This is a standalone contract that provides randomness by utilizing Commit/Reveal pattern.
// Any contract that is added as a "trusted consumer" can make request for a random number. 
contract PenguinRandomizer is IPenguinRandomizer, CommitRevealRandomizer, Ownable, AccessControl {
    /*
     *   Roles definition:
     *      - CONSUMER_ADMIN_ROLE: admin role of role CONSUMER_ROLE, 
     *                             that is permitted to add/remove contract from CONSUMER_ROLE role.
     *                             Admin role of this role is DEFAULT_ADMIN_ROLE
     *      - CONSUMER_ROLE:       only contracts that are granted this role can request for randomness
     */
    bytes32 public constant CONSUMER_ADMIN_ROLE = keccak256("CONSUMER_ADMIN_ROLE"); 
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE"); 

    // trusted delaers who can deal with secrets
    mapping(address => bool) public isTrustedDealer;
    
    // The gas limit for consumer callback function (if exceeded, callback TX will be reverted)
    // Note: just define value here, not implemented the logic yet
    uint256 public callbackGasLimit = 800000;
    
    constructor() {
        // grant "default admin" role for contract owner
        _grantRole(DEFAULT_ADMIN_ROLE, owner());
        // change admin role of "consumer" role from "default admin" to "consumer admin"
        _setRoleAdmin(CONSUMER_ROLE, CONSUMER_ADMIN_ROLE);
    }
    
    modifier onlyTrustedDealer(){
        require(isTrustedDealer[msg.sender], "Only trusted dealer");
        _;
    }
    
    
    function requestRandomNumber(bytes memory _input) external virtual 
    override(IRandomizer, CommitRevealRandomizer) 
    returns(uint256)
    {
        require(isTrustedConsumer(msg.sender), "Only trusted consumer");
       return _requestRandomNumber(_input);
     }
    
    
    function commit(uint256[] memory _secretHashes) external virtual override onlyTrustedDealer{
        _commit(_secretHashes);
    }
    
    
    function reveal(uint256 _hash, uint256 _secret) external virtual override onlyTrustedDealer{
        _reveal(_hash, _secret);
    }
    
    
    function addConsumerAdmin(address _toAdd) external{
        grantRole(CONSUMER_ADMIN_ROLE, _toAdd);
    }
    
    
    function removeConsumerAdmin(address _toRemove) external{
        revokeRole(CONSUMER_ADMIN_ROLE, _toRemove);
    }
    
    
    function addConsumer(address _toAdd) external override{
        grantRole(CONSUMER_ROLE, _toAdd);
    }
    
    
    function removeConsumer(address _toRemove) external override{
        revokeRole(CONSUMER_ROLE, _toRemove);
    }
    
    function isTrustedConsumer(address _toCheck) public view returns(bool) {
        return hasRole(CONSUMER_ROLE, _toCheck);
    }
    
    
    function addTrustedDealer(address _toAdd) external onlyOwner {
        isTrustedDealer[_toAdd] = true;
    }
    
    
    function removeTrustedDealer(address _toRemove) external onlyOwner {
        isTrustedDealer[_toRemove] = false;
    }
    
    
    function setCallbackGasLimit(uint256 _value) external onlyOwner {
        callbackGasLimit = _value;
    }
    
}