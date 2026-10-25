// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITape} from "./interfaces/ITape.sol";
import {IncrementalMerkle} from "./libraries/IncrementalMerkle.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title Tape — attest, dispute, finalize
/// @notice Anyone may post an event that carries a valid attester signature for its symbol, bonding
///         `postBond`. Anyone may challenge it inside the window, bonding `challengeBond`. An
///         unchallenged event finalizes after the window; a challenged one waits for the reviewer.
///         The loser's bond goes to the winner. Finalized events become storage hooks read, plus a
///         leaf in an append-only Merkle tree whose root is `eventsRoot()`.
contract Tape is ITape, EIP712 {
    using IncrementalMerkle for IncrementalMerkle.Tree;

    bytes32 public constant EVENT_TYPEHASH =
        keccak256("Event(bytes32 symbol,uint8 kind,uint64 effective,uint256 value,uint64 nonce)");

    struct Pending {
        Event e;
        address poster;
        address challenger;
        uint64 postedAt;
        Status status;
    }

    address public reviewer;
    uint64 public immutable disputeWindow;
    uint256 public immutable postBond;
    uint256 public immutable challengeBond;

    mapping(bytes32 symbol => address) public attesterOf;
    mapping(bytes32 id => Pending) internal _pending;
    mapping(bytes32 symbol => bool) internal _halted;
    mapping(bytes32 symbol => Action) internal _latest;
    mapping(bytes32 symbol => mapping(uint64 nonce => bool)) public nonceUsed;
    mapping(bytes32 symbol => bytes32[]) internal _eventsOf;

    IncrementalMerkle.Tree internal _tree;

    /// @notice Paid from `rewardPool` to whoever lands `finalize()`; the on-chain wage for operators.
    uint256 public finalizeReward;
    /// @notice ETH set aside for finalizer rewards, kept separate from bonds. Anyone may `fund()` it.
    uint256 public rewardPool;

    event Funded(address indexed from, uint256 amount, uint256 pool);
    event FinalizeRewardSet(uint256 amount);
    event RewardPaid(bytes32 indexed id, address indexed to, uint256 amount);

    modifier onlyReviewer() {
        if (msg.sender != reviewer) revert NotReviewer();
        _;
    }

    constructor(address reviewer_, uint64 disputeWindow_, uint256 postBond_, uint256 challengeBond_)
        EIP712("NEO Tape", "1")
    {
        reviewer = reviewer_;
        disputeWindow = disputeWindow_;
        postBond = postBond_;
        challengeBond = challengeBond_;
        _tree.init();
    }

    // ------------------------------------------------------------------ admin

    function setAttester(bytes32 symbol, address attester) external onlyReviewer {
        attesterOf[symbol] = attester;
        emit AttesterSet(symbol, attester);
    }

    function setReviewer(address next) external onlyReviewer {
        reviewer = next;
    }

    function setFinalizeReward(uint256 amount) external onlyReviewer {
        finalizeReward = amount;
        emit FinalizeRewardSet(amount);
    }

    /// @notice Add ETH to the finalizer reward pool. Treasury, issuers or anyone who wants events finalized promptly.
    function fund() external payable {
        rewardPool += msg.value;
        emit Funded(msg.sender, msg.value, rewardPool);
    }

    receive() external payable {
        rewardPool += msg.value;
        emit Funded(msg.sender, msg.value, rewardPool);
    }

    // ------------------------------------------------------------------ reads

    function isHalted(bytes32 symbol) external view returns (bool) {
        return _halted[symbol];
    }

    function action(bytes32 symbol) external view returns (Kind, uint64, uint256) {
        Action storage a = _latest[symbol];
        return (a.kind, a.effective, a.value);
    }

    function eventsRoot() external view returns (bytes32) {
        return _tree.root();
    }

    function eventCount() external view returns (uint256) {
        return _tree.count;
    }

    function pending(bytes32 id) external view returns (Pending memory) {
        return _pending[id];
    }

    function eventsOf(bytes32 symbol) external view returns (bytes32[] memory) {
        return _eventsOf[symbol];
    }

    function hasAttester(bytes32 symbol) external view returns (bool) {
        return attesterOf[symbol] != address(0);
    }

    function leafOf(Event calldata e) public pure returns (bytes32) {
        return keccak256(abi.encode(e.symbol, e.kind, e.effective, e.value, e.nonce));
    }

    function idOf(Event calldata e) public pure returns (bytes32) {
        return leafOf(e);
    }

    function verify(bytes32 leaf, uint256 index, bytes32[] calldata proof) external view returns (bool) {
        return IncrementalMerkle.verify(leaf, index, proof, _tree.root());
    }

    function digestOf(Event calldata e) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(EVENT_TYPEHASH, e.symbol, e.kind, e.effective, e.value, e.nonce)));
    }

    // ------------------------------------------------------------------ lifecycle

    function post(Event calldata e, bytes calldata attesterSig) external payable returns (bytes32 id) {
        if (msg.value != postBond) revert WrongBond(postBond, msg.value);
        address attester = attesterOf[e.symbol];
        if (attester == address(0)) revert NoAttester(e.symbol);
        if (ECDSA.recover(digestOf(e), attesterSig) != attester) revert BadSignature();
        if (nonceUsed[e.symbol][e.nonce]) revert AlreadyPosted(leafOf(e));
        nonceUsed[e.symbol][e.nonce] = true;

        id = leafOf(e);
        Pending storage p = _pending[id];
        p.e = e;
        p.poster = msg.sender;
        p.postedAt = uint64(block.timestamp);
        p.status = Status.Pending;
        _eventsOf[e.symbol].push(id);
        emit Posted(id, e.symbol, e.kind, msg.sender);
    }

    function challenge(bytes32 id) external payable {
        Pending storage p = _pending[id];
        if (p.status != Status.Pending) revert NotPending(id);
        if (msg.value != challengeBond) revert WrongBond(challengeBond, msg.value);
        uint64 closesAt = p.postedAt + disputeWindow;
        if (block.timestamp >= closesAt) revert WindowClosed(closesAt);
        p.challenger = msg.sender;
        p.status = Status.Challenged;
        emit Challenged(id, msg.sender);
    }

    function finalize(bytes32 id) external {
        Pending storage p = _pending[id];
        if (p.status != Status.Pending) revert NotPending(id);
        uint64 closesAt = p.postedAt + disputeWindow;
        if (block.timestamp < closesAt) revert WindowOpen(closesAt);
        _apply(id, p);
        _pay(p.poster, postBond);
        _reward(id, msg.sender);
    }

    /// @notice Reviewer settles a challenged event. If the event is correct, it finalizes and the
    ///         challenger's bond goes to the poster. If not, it is rejected and the poster's bond goes
    ///         to the challenger.
    function resolve(bytes32 id, bool eventIsCorrect) external onlyReviewer {
        Pending storage p = _pending[id];
        if (p.status != Status.Challenged) revert NotPending(id);
        if (eventIsCorrect) {
            _apply(id, p);
            _pay(p.poster, postBond + challengeBond);
        } else {
            p.status = Status.Rejected;
            _pay(p.challenger, postBond + challengeBond);
            emit Rejected(id, p.challenger);
        }
    }

    // ------------------------------------------------------------------ internals

    function _apply(bytes32 id, Pending storage p) internal {
        Event memory e = p.e;
        p.status = Status.Finalized;
        if (e.kind == Kind.Halt) {
            _halted[e.symbol] = e.value == 1;
        } else {
            _latest[e.symbol] = Action({kind: e.kind, effective: e.effective, value: e.value});
        }
        uint256 index = _tree.count;
        _tree.insert(id);
        emit Finalized(id, e.symbol, index, _tree.root(), p.poster);
    }

    /// @dev Pays the finalizer if the pool can cover it; never blocks finalization when it cannot.
    function _reward(bytes32 id, address to) internal {
        uint256 amount = finalizeReward;
        if (amount == 0 || rewardPool < amount) return;
        rewardPool -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (ok) emit RewardPaid(id, to, amount);
        else rewardPool += amount; // a finalizer that cannot receive ETH forfeits the reward
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
