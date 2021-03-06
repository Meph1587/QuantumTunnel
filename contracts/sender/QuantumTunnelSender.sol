// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ICallback} from "@connext/nxtp-contracts/contracts/core/promise/interfaces/ICallback.sol";
import {QuantumTunnelReceiver} from "../receiver/QuantumTunnelReceiver.sol";

import "../ConnextAdapter.sol";

contract QuantumTunnelSender is Ownable, ICallback, ConnextAdapter {
    uint256 immutable WEEK = 1 weeks;

    uint256 public lastWithdraw;
    uint256 public minWeeksLocked;

    bool public emergencyWithdrawEnabled;

    // addresses of contract on receiver-chains
    mapping(uint32 => address) public receiverContract;

    // addresses of contract that can be tunneled
    mapping(address => bool) public tokenIsEnabled;

    mapping(address => mapping(uint256 => address)) public originalTokenOwner;
    mapping(address => mapping(uint256 => uint32)) public tokenTunneledTo;
    mapping(address => mapping(uint256 => uint256)) public lockExpires;
    mapping(address => mapping(uint256 => uint256)) public unlockWithdraw;

    struct callbackData {
        address owner;
        address token;
        uint256 tokenId;
    }

    event Deposited(
        address indexed owner,
        address indexed token,
        uint256 tokenId,
        uint256 lock
    );
    event Withdrawn(
        address indexed owner,
        address indexed token,
        uint256 tokenId
    );
    event EmergencyWithdrawn(
        address indexed owner,
        address indexed token,
        uint256 tokenId
    );
    event CallbackCalled(
        bytes32 indexed transferId,
        bytes indexed data,
        bool success
    );

    constructor(
        address _connext,
        uint32 _deploymentDomain,
        address _transactingAssetId
    )
        Ownable()
        ConnextAdapter(_connext, _deploymentDomain, _transactingAssetId)
    {
        lastWithdraw = block.timestamp;
    }

    /// @dev Deposits an ERC721 Token into the bridge and initiates xchain transfer
    /// @param token The ERC721 Token contract to be used, must be enabled by owner
    /// @param tokenId Token ID to be transfered
    /// @param destinationDomain Domain Id of receiver-chain, see connext docs
    /// @param nrWeeksLocked for how many weeks the tokens can't be withdrawn
    /// @param relayerFee fee paid to router for xCall
    /// @param callbackFee fee paid to router for callback transaction
    /// msg.value needs to be higher then relayerFee + callbackFee, to cover all costs
    function deposit(
        ERC721 token,
        uint256 tokenId,
        uint32 destinationDomain,
        uint32 nrWeeksLocked,
        uint256 relayerFee,
        uint256 callbackFee
    ) external payable {
        require(
            msg.value >= relayerFee + callbackFee,
            "QTSender: value to low to cover relayer and callback fee"
        );
        require(
            tokenIsEnabled[address(token)],
            "QTSender: token is not enabled"
        );
        require(
            nrWeeksLocked >= minWeeksLocked,
            "QTSender: lock duration is below min duration"
        );
        require(
            receiverContract[destinationDomain] != address(0),
            "QTSender: no receiver contract set for destination"
        );
        require(
            tokenTunneledTo[address(token)][tokenId] == 0,
            "QTSender: token is already tunneled somewhere"
        );

        token.transferFrom(msg.sender, address(this), tokenId);

        uint256 lockExpiresAt = block.timestamp + (nrWeeksLocked * WEEK);

        lockExpires[address(token)][tokenId] = lockExpiresAt;
        originalTokenOwner[address(token)][tokenId] = msg.sender;
        tokenTunneledTo[address(token)][tokenId] = destinationDomain;

        bytes memory callData = abi.encodeWithSelector(
            QuantumTunnelReceiver(receiverContract[destinationDomain])
                .executeXCallMint
                .selector,
            msg.sender,
            address(token),
            tokenId,
            lockExpiresAt
        );

        _xcall(
            destinationDomain,
            callData,
            receiverContract[destinationDomain],
            callbackFee,
            relayerFee
        );

        emit Deposited(msg.sender, address(token), tokenId, lockExpiresAt);
    }

    /// @dev Called by executer from receiver-chain to withdraw token to original owner
    function executeXCallWithdraw(address token, uint256 tokenId)
        external
        onlyExecutor
    {
        ERC721(token).safeTransferFrom(
            address(this),
            originalTokenOwner[token][tokenId],
            tokenId
        );

        lockExpires[token][tokenId] = 0;
        originalTokenOwner[token][tokenId] = address(0);
        tokenTunneledTo[token][tokenId] = 0;

        lastWithdraw = block.timestamp;

        emit Withdrawn(msg.sender, address(token), tokenId);
    }

    /// @dev Called by executer from receiver-chain after successfull deposit
    /// if the xCall fails the token deposited can be withdrawn after 3 days
    function callback(
        bytes32 transferId,
        bool success,
        bytes memory data
    ) external override onlyExecutor {
        callbackData memory returnData = abi.decode(data, (callbackData));

        if (!success) {
            // make token withdrawable through emergency transfer 3days after
            unlockWithdraw[returnData.token][returnData.tokenId] =
                block.timestamp +
                3 days;
        }
        emit CallbackCalled(transferId, data, success);
    }

    /// @dev In case anything goes wrong this can be used to rescue locked tokens
    /// this does not burn tokens on receiver chain !!
    /// @param token The ERC721 Token contract to be used
    /// @param tokenId Token ID to be transfered
    function emergencyWithdraw(ERC721 token, uint256 tokenId) external {
        // this can only be used if at least one of the following are true
        require(
            // owner activated emergency withdraw
            emergencyWithdrawEnabled ||
                // no withdraw happend in last 4 weeks
                (lastWithdraw + 4 weeks < block.timestamp) ||
                // a bridge execution for this token failed and 3 days passed
                (unlockWithdraw[address(token)][tokenId] != 0 &&
                    block.timestamp > unlockWithdraw[address(token)][tokenId]),
            "QTSender: emergency withdraw not allowed"
        );
        require(
            msg.sender == originalTokenOwner[address(token)][tokenId],
            "QTSender: not called by the owner of this token"
        );

        //withdraw back to original owner
        token.transferFrom(
            address(this),
            originalTokenOwner[address(token)][tokenId],
            tokenId
        );

        emit EmergencyWithdrawn(msg.sender, address(token), tokenId);
    }

    /// @dev allows owner to enable emergency withdraws
    function enableEmergencyWithdraw() external onlyOwner {
        emergencyWithdrawEnabled = true;
    }

    /// @dev enables a not token to be tunneld
    function enableToken(address _token) external onlyOwner {
        tokenIsEnabled[_token] = true;
    }

    /// @dev sets a minimum amount of time for which the token need to stay on receiver-chain
    function setLockDuration(uint256 _minWeeksLocked) external onlyOwner {
        minWeeksLocked = _minWeeksLocked;
    }

    /// @dev sets the receiver contarct on the reciver-chain
    function setDestinationReceiver(uint32 _domainId, address _receiver)
        external
        onlyOwner
    {
        receiverContract[_domainId] = _receiver;
        setAllowedOrigin(_domainId, _receiver);
    }
}
