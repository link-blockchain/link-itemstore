pragma solidity ^0.4.14;

import "./itemstore_interface.sol";
import "./itemstore_registry.sol";


/**
 * @title ItemStoreIpfsSha256
 * @author Jonathan Brown <jbrown@link-blockchain.org>
 * @dev ItemStore implementation where each item revision is a SHA256 IPFS hash.
 */
contract ItemStoreIpfsSha256 is ItemStoreInterface {

    enum State { Unused, Exists, Retracted }

    byte constant UPDATABLE = 0x01;           // True if the item is updatable. After creation can only be disabled.
    byte constant ENFORCE_REVISIONS = 0x02;   // True if the item is enforcing revisions. After creation can only be enabled.
    byte constant RETRACTABLE = 0x04;         // True if the item can be retracted. After creation can only be disabled.
    byte constant TRANSFERABLE = 0x08;        // True if the item be transfered to another user or disowned. After creation can only be disabled.
    byte constant ANONYMOUS = 0x10;           // True if the item should not have an owner.

    /**
     * @dev Single slot structure of item info.
     */
    struct ItemInfo {
        State state;            // Unused, exists or retracted.
        byte flags;             // Packed item settings.
        uint32 revisionCount;   // Number of revisions including revision 0.
        address owner;          // Who owns this item.
    }

    /**
     * @dev Mapping of itemId to item info.
     */
    mapping (bytes20 => ItemInfo) itemInfo;

    /**
     * @dev Mapping of itemId to mapping of revision number to IPFS hash.
     */
    mapping (bytes20 => mapping (uint => bytes32)) itemRevisionIpfsHashes;

    /**
     * @dev Mapping of itemId to mapping of transfer recipient addresses to enabled.
     */
    mapping (bytes20 => mapping (address => bool)) enabledTransfers;

    /**
     * @dev Id of this instance of ItemStore. Unique across all blockchains.
     */
    bytes12 contractId;

    /**
     * @dev An item revision has been published.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision (the highest at time of logging).
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     */
    event Publish(bytes20 indexed itemId, uint revisionId, bytes32 ipfsHash);

    /**
     * @dev Revert if the item has not been used before or it has been retracted.
     * @param itemId Id of the item.
     */
    modifier exists(bytes20 itemId) {
        require (itemInfo[itemId].state == State.Exists);
        _;
    }

    /**
     * @dev Revert if the owner of the item is not the message sender.
     * @param itemId Id of the item.
     */
    modifier isOwner(bytes20 itemId) {
        require (itemInfo[itemId].owner == msg.sender);
        _;
    }

    /**
     * @dev Revert if the item is not updatable.
     * @param itemId Id of the item.
     */
    modifier isUpdatable(bytes20 itemId) {
        require (itemInfo[itemId].flags & UPDATABLE != 0);
        _;
    }

    /**
     * @dev Revert if the item is not enforcing revisions.
     * @param itemId Id of the item.
     */
    modifier isNotEnforceRevisions(bytes20 itemId) {
        require (itemInfo[itemId].flags & ENFORCE_REVISIONS == 0);
        _;
    }

    /**
     * @dev Revert if the item is not retractable.
     * @param itemId Id of the item.
     */
    modifier isRetractable(bytes20 itemId) {
        require (itemInfo[itemId].flags & RETRACTABLE != 0);
        _;
    }

    /**
     * @dev Revert if the item is not transferable.
     * @param itemId Id of the item.
     */
    modifier isTransferable(bytes20 itemId) {
        require (itemInfo[itemId].flags & TRANSFERABLE != 0);
        _;
    }

    /**
     * @dev Revert if the item is not transferable to a specific user.
     * @param itemId Id of the item.
     * @param recipient Address of the user.
     */
    modifier isTransferEnabled(bytes20 itemId, address recipient) {
        require (enabledTransfers[itemId][recipient]);
        _;
    }

    /**
     * @dev Revert if the item only has one revision.
     * @param itemId Id of the item.
     */
    modifier hasAdditionalRevisions(bytes20 itemId) {
        require (itemInfo[itemId].revisionCount > 1);
        _;
    }

    /**
     * @dev Revert if a specific item revision does not exist.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision.
     */
    modifier revisionExists(bytes20 itemId, uint revisionId) {
        require (revisionId < itemInfo[itemId].revisionCount);
        _;
    }

    /**
     * @dev Constructor.
     * @param registry Address of ItemStoreRegistry contract to register with.
     */
    function ItemStoreIpfsSha256(ItemStoreRegistry registry) {
        // Create id for this contract.
        contractId = bytes12(keccak256(this, block.blockhash(block.number - 1)));
        // Register this contract.
        registry.register(contractId);
    }

    /**
     * @dev Creates a new item. It is guaranteed that different users will never receive the same itemId, even before consensus has been reached. This prevents itemId sniping.
     * @param flags Packed item settings.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     * @param nonce Unique value that this user has never used before to create a new item.
     * @return itemId Id of the item.
     */
    function create(byte flags, bytes32 ipfsHash, bytes32 nonce) external returns (bytes20 itemId) {
        // Generate the itemId.
        itemId = bytes20(keccak256(msg.sender, nonce));
        // Make sure this itemId has not been used before.
        require (itemInfo[itemId].state == State.Unused);
        // Store item info in state.
        itemInfo[itemId] = ItemInfo({
            state: State.Exists,
            flags: flags,
            revisionCount: 1,
            owner: (flags & ANONYMOUS == 0) ? msg.sender : 0,
        });
        // Store the IPFS hash.
        itemRevisionIpfsHashes[itemId][0] = ipfsHash;
        // Log the first revision.
        Publish(itemId, 0, ipfsHash);
    }

    /**
     * @dev Create a new item revision.
     * @param itemId Id of the item.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     * @return revisionId The new revisionId.
     */
    function createNewRevision(bytes20 itemId, bytes32 ipfsHash) external isOwner(itemId) isUpdatable(itemId) returns (uint revisionId) {
        // Increment the number of revisions.
        revisionId = itemInfo[itemId].revisionCount++;
        // Store the IPFS hash.
        itemRevisionIpfsHashes[itemId][revisionId] = ipfsHash;
        // Log the revision.
        Publish(itemId, revisionId, ipfsHash);
    }

    /**
     * @dev Update an item's latest revision.
     * @param itemId Id of the item.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     */
    function updateLatestRevision(bytes20 itemId, bytes32 ipfsHash) external isOwner(itemId) isUpdatable(itemId) isNotEnforceRevisions(itemId) {
        uint revisionId = itemInfo[itemId].revisionCount - 1;
        // Update the IPFS hash.
        itemRevisionIpfsHashes[itemId][revisionId] = ipfsHash;
        // Log the revision.
        Publish(itemId, revisionId, ipfsHash);
    }

    /**
     * @dev Retract an item's latest revision. Revision 0 cannot be retracted.
     * @param itemId Id of the item.
     */
    function retractLatestRevision(bytes20 itemId) external isOwner(itemId) isUpdatable(itemId) isNotEnforceRevisions(itemId) hasAdditionalRevisions(itemId) {
        // Decrement the number of revisions.
        uint revisionId = --itemInfo[itemId].revisionCount;
        // Delete the IPFS hash.
        delete itemRevisionIpfsHashes[itemId][revisionId];
        // Log the revision retraction.
        RetractRevision(itemId, revisionId);
    }

    /**
     * @dev Delete all an item's revisions and replace it with a new item.
     * @param itemId Id of the item.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     */
    function restart(bytes20 itemId, bytes32 ipfsHash) external isOwner(itemId) isUpdatable(itemId) isNotEnforceRevisions(itemId) {
        // Delete all the IPFS hashes except the first one.
        for (uint i = 1; i < itemInfo[itemId].revisionCount; i++) {
            delete itemRevisionIpfsHashes[itemId][i];
        }
        // Update the item state info.
        itemInfo[itemId].revisionCount = 1;
        // Update the first IPFS hash.
        itemRevisionIpfsHashes[itemId][0] = ipfsHash;
        // Log the revision.
        Publish(itemId, 0, ipfsHash);
    }

    /**
     * @dev Retract an item.
     * @param itemId Id of the item. This itemId can never be used again.
     */
    function retract(bytes20 itemId) external isOwner(itemId) isRetractable(itemId) {
        // Delete all the IPFS hashes.
        for (uint i = 0; i < itemInfo[itemId].revisionCount; i++) {
            delete itemRevisionIpfsHashes[itemId][i];
        }
        // Mark this item as retracted.
        itemInfo[itemId] = ItemInfo({
            state: State.Retracted,
            flags: 0,
            revisionCount: 0,
            owner: 0,
        });
        // Log the item retraction.
        Retract(itemId);
    }

    /**
     * @dev Enable transfer of the item to the current user.
     * @param itemId Id of the item.
     */
    function transferEnable(bytes20 itemId) external isTransferable(itemId) {
        // Record in state that the current user will accept this item.
        enabledTransfers[itemId][msg.sender] = true;
    }

    /**
     * @dev Disable transfer of the item to the current user.
     * @param itemId Id of the item.
     */
    function transferDisable(bytes20 itemId) external isTransferEnabled(itemId, msg.sender) {
        // Record in state that the current user will not accept this item.
        enabledTransfers[itemId][msg.sender] = false;
    }

    /**
     * @dev Transfer an item to a new user.
     * @param itemId Id of the item.
     * @param recipient Address of the user to transfer to item to.
     */
    function transfer(bytes20 itemId, address recipient) external isOwner(itemId) isTransferable(itemId) isTransferEnabled(itemId, recipient) {
        // Update ownership of the item.
        itemInfo[itemId].owner = recipient;
        // Disable this transfer in future and free up the slot.
        enabledTransfers[itemId][recipient] = false;
        // Log the transfer.
        Transfer(itemId, recipient);
    }

    /**
     * @dev Disown an item.
     * @param itemId Id of the item.
     */
    function disown(bytes20 itemId) external isOwner(itemId) isTransferable(itemId) {
        // Remove the owner from the item's state.
        delete itemInfo[itemId].owner;
        // Log that the item has been disowned.
        Disown(itemId);
    }

    /**
     * @dev Set an item as not updatable.
     * @param itemId Id of the item.
     */
    function setNotUpdatable(bytes20 itemId) external isOwner(itemId) {
        // Record in state that the item is not updatable.
        itemInfo[itemId].flags &= ~UPDATABLE;
        // Log that the item is not updatable.
        SetNotUpdatable(itemId);
    }

    /**
     * @dev Set an item to enforce revisions.
     * @param itemId Id of the item.
     */
    function setEnforceRevisions(bytes20 itemId) external isOwner(itemId) {
        // Record in state that all changes to this item must be new revisions.
        itemInfo[itemId].flags |= ENFORCE_REVISIONS;
        // Log that the item now enforces new revisions.
        SetEnforceRevisions(itemId);
    }

    /**
     * @dev Set an item to not be retractable.
     * @param itemId Id of the item.
     */
    function setNotRetractable(bytes20 itemId) external isOwner(itemId) {
        // Record in state that the item is not retractable.
        itemInfo[itemId].flags &= ~RETRACTABLE;
        // Log that the item is not retractable.
        SetNotRetractable(itemId);
    }

    /**
     * @dev Set an item to not be transferable.
     * @param itemId Id of the item.
     */
    function setNotTransferable(bytes20 itemId) external isOwner(itemId) {
        // Record in state that the item is not transferable.
        itemInfo[itemId].flags &= ~TRANSFERABLE;
        // Log that the item is not transferable.
        SetNotTransferable(itemId);
    }

    /**
     * @dev Get the id for this ItemStore contract.
     * @return Id of the contract.
     */
    function getContractId() external constant returns (bytes12) {
        return contractId;
    }

    /**
     * @dev Check if an item exists.
     * @param itemId Id of the item.
     * @return exists True if the item exists.
     */
    function getExists(bytes20 itemId) external constant returns (bool exists) {
        exists = itemInfo[itemId].state == State.Exists;
    }

    /**
     * @dev Get the IPFS hashes for all of an item's revisions.
     * @param itemId Id of the item.
     * @return ipfsHashes Revision IPFS hashes.
     */
    function _getAllRevisionIpfsHashes(bytes20 itemId) internal returns (bytes32[] ipfsHashes) {
        uint revisionCount = itemInfo[itemId].revisionCount;
        ipfsHashes = new bytes32[](revisionCount);
        for (uint revisionId = 0; revisionId < revisionCount; revisionId++) {
            ipfsHashes[revisionId] = itemRevisionIpfsHashes[itemId][revisionId];
        }
    }

    /**
     * @dev Get info about an item.
     * @param itemId Id of the item.
     * @return flags Packed item settings.
     * @return owner Owner of the item.
     * @return revisionCount How many revisions the item has.
     * @return ipfsHashes IPFS hash of each revision.
     */
    function getInfo(bytes20 itemId) external constant exists(itemId) returns (byte flags, address owner, uint revisionCount, bytes32[] ipfsHashes) {
        ItemInfo info = itemInfo[itemId];
        flags = info.flags;
        owner = info.owner;
        revisionCount = info.revisionCount;
        ipfsHashes = _getAllRevisionIpfsHashes(itemId);
    }

    /**
     * @dev Get all an item's flags.
     * @param itemId Id of the item.
     * @return flags Packed item settings.
     */
    function getFlags(bytes20 itemId) external constant exists(itemId) returns (byte flags) {
        flags = itemInfo[itemId].flags;
    }

    /**
     * @dev Determine if an item is updatable.
     * @param itemId Id of the item.
     * @return updatable True if the item is updatable.
     */
    function getUpdatable(bytes20 itemId) external constant exists(itemId) returns (bool updatable) {
        updatable = itemInfo[itemId].flags & UPDATABLE != 0;
    }

    /**
     * @dev Determine if an item enforces revisions.
     * @param itemId Id of the item.
     * @return enforceRevisions True if the item enforces revisions.
     */
    function getEnforceRevisions(bytes20 itemId) external constant exists(itemId) returns (bool enforceRevisions) {
        enforceRevisions = itemInfo[itemId].flags & ENFORCE_REVISIONS != 0;
    }

    /**
     * @dev Determine if an item is retractable.
     * @param itemId Id of the item.
     * @return retractable True if the item is item retractable.
     */
    function getRetractable(bytes20 itemId) external constant exists(itemId) returns (bool retractable) {
        retractable = itemInfo[itemId].flags & RETRACTABLE != 0;
    }

    /**
     * @dev Determine if an item is transferable.
     * @param itemId Id of the item.
     * @return transferable True if the item is transferable.
     */
    function getTransferable(bytes20 itemId) external constant exists(itemId) returns (bool transferable) {
        transferable = itemInfo[itemId].flags & TRANSFERABLE != 0;
    }

    /**
     * @dev Get the owner of an item.
     * @param itemId Id of the item.
     * @return owner Owner of the item.
     */
    function getOwner(bytes20 itemId) external constant exists(itemId) returns (address owner) {
        owner = itemInfo[itemId].owner;
    }

    /**
     * @dev Get the number of revisions an item has.
     * @param itemId Id of the item.
     * @return revisionCount How many revisions the item has.
     */
    function getRevisionCount(bytes20 itemId) external constant exists(itemId) returns (uint revisionCount) {
        revisionCount = itemInfo[itemId].revisionCount;
    }

   /**
     * @dev Get the IPFS hash for a specific item revision.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision.
     * @return ipfsHash IPFS hash of the specified revision.
     */
    function getRevisionIpfsHash(bytes20 itemId, uint revisionId) external constant revisionExists(itemId, revisionId) returns (bytes32 ipfsHash) {
        ipfsHash = itemRevisionIpfsHashes[itemId][revisionId];
    }

    /**
     * @dev Get the IPFS hashes for all of an item's revisions.
     * @param itemId Id of the item.
     * @return ipfsHashes IPFS hashes of all revisions of the item.
     */
    function getAllRevisionIpfsHashes(bytes20 itemId) external constant returns (bytes32[] ipfsHashes) {
        ipfsHashes = _getAllRevisionIpfsHashes(itemId);
    }

}