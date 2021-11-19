// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
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

// Penguin randomizer interface that restricts randomness requests to trusted consumers only 
interface IPenguinRandomizer is IRandomizer {
    // add trusted consumer
    function addConsumer(address _consumer) external;
    // remove consumer from trusted list
    function removeConsumer(address _consumer) external;
}


contract PenguinVRF is IPenguinRandomizer, VRFConsumerBase, Withdrawable, Ownable, AccessControl{
    // TODO: Settings for VRF client. Please change them when deploy on prod environment -------------------------
    address constant internal LINK_TOKEN = 0x326C977E6efc84E512bB9C30f76E30c160eD06FB;
    address constant internal VRF_CONTRACT = 0x8C7382F9D8f56b33781fE506E897a4F1e2d17255;
    bytes32 constant internal KEY_HASH = 0x6e75b569a01ef56d18cab6a8e71e6600d6ce853834d4a5748b720d06f878b3a4;
    uint256 constant internal VRF_DEFAULT_CONSUMING_FEE = 0.0001 * ( 10 ** 18); // 0.0001 LINK (Varies by network)
    // -----------------------------------------------------------------------------------------------------------
    
    /*
     *   Roles definition:
     *      - CONSUMER_ADMIN_ROLE: admin role of role CONSUMER_ROLE, 
     *                             that is permitted to add/remove contract from CONSUMER_ROLE role.
     *                             Admin role of this role is DEFAULT_ADMIN_ROLE
     *      - CONSUMER_ROLE:       only contracts that are granted this role can request for randomness
     */
    bytes32 public constant CONSUMER_ADMIN_ROLE = keccak256("CONSUMER_ADMIN_ROLE"); 
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE"); 
    
    struct RequestInfo {
        address caller;
        bool fulfilled;
    }
    // mapping: requestId => RequestInfo
    mapping(uint256 => RequestInfo) public requests;
    
    uint256 public consumingFee;
    
    constructor() 
    VRFConsumerBase(VRF_CONTRACT, LINK_TOKEN)
    Withdrawable(new address[](0))
    {
        consumingFee = VRF_DEFAULT_CONSUMING_FEE;
        // grant "default admin" role for contract owner
        _grantRole(DEFAULT_ADMIN_ROLE, owner());
        // change admin role of "consumer" role from "default admin" to "consumer admin"
        _setRoleAdmin(CONSUMER_ROLE, CONSUMER_ADMIN_ROLE);
    }
    
    /**
     * Request a random number
     * (can be called only by registered game house)
     */    
    function requestRandomNumber(bytes calldata) external virtual override returns(uint256){
        require(isTrustedConsumer(msg.sender), "Only trusted consumer");
        require(LINK.balanceOf(address(this)) >= consumingFee, "Not enough LINK");
        uint256 requestId = uint256(requestRandomness(KEY_HASH, consumingFee));
        requests[requestId].caller = msg.sender;
        return uint256(requestId);
    }
    
    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        uint256 uintRequestId = uint256(requestId);
        if(!requests[uintRequestId].fulfilled){
            address requestor =  requests[uintRequestId].caller;
            requests[uintRequestId].fulfilled = true;
            if(requestor != address(0)){
                IRandomnessConsumer(requestor).fulfillRandomness(uint256(requestId), randomness);
            }   
        }
    }
    
    function isReady() external view override returns(bool) {
        return (LINK.balanceOf(address(this)) >= consumingFee);
    }
    
    
    function checkRequestState(uint256 _requestId) external view override returns(uint8){
        if(requests[_requestId].caller == address(0)){
            // Invalid request
            return 0;
        }
        
        if(requests[_requestId].fulfilled){
            // fulfilled
            return 2;
        } else {
            // on-going
            return 1;
        }
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
    
    
    function setConsumingFee(uint256 _value) external onlyOwner {
        consumingFee = _value;
    }
    
    function withdraw(address _token, uint256 _amount, address _to) external onlyOwner {
        _safeTokenTransfer(_token, _amount, _to);
    }
}