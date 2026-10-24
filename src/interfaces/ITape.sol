// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ITape — the corporate-action record every NEO hook reads
/// @notice One contract per chain. Events are posted with an issuer attester's signature,
///         held for a bonded dispute window, then finalized into plain storage and an
///         append-only Merkle tree. Hooks read `isHalted` / `action` as views over storage;
///         nothing in the swap path calls out to an oracle.
interface ITape {
    enum Kind {
        None,
        Split, // value = new shares per old share, scaled 1e4 (4-for-1 => 40_000)
        Dividend, // value = cash per share in quote-asset minor units
        Halt, // value = 1 to halt, 0 to lift
        Rename // value = new symbol as bytes32 cast to uint256
    }

    enum Status {
        Unknown,
        Pending,
        Challenged,
        Finalized,
        Rejected
    }

    struct Event {
        bytes32 symbol;
        Kind kind;
        uint64 effective; // unix time the action takes effect
        uint256 value;
        uint64 nonce; // attester-chosen, unique per symbol
    }

    struct Action {
        Kind kind;
        uint64 effective;
        uint256 value;
    }

    // ---- reads used by hooks ----
    function isHalted(bytes32 symbol) external view returns (bool);
    function action(bytes32 symbol) external view returns (Kind kind, uint64 effective, uint256 value);
    function eventsRoot() external view returns (bytes32);
    function eventCount() external view returns (uint256);
    function leafOf(Event calldata e) external pure returns (bytes32);
    function verify(bytes32 leaf, uint256 index, bytes32[] calldata proof) external view returns (bool);
    /// @notice Every event id ever posted for a symbol, in posting order (pending, challenged, finalized and rejected).
    function eventsOf(bytes32 symbol) external view returns (bytes32[] memory);
    /// @notice Whether the symbol has a data source at all: an attester is set.
    function hasAttester(bytes32 symbol) external view returns (bool);

    // ---- lifecycle ----
    function post(Event calldata e, bytes calldata attesterSig) external payable returns (bytes32 id);
    function challenge(bytes32 id) external payable;
    function finalize(bytes32 id) external;
    function resolve(bytes32 id, bool eventIsCorrect) external;

    // ---- events ----
    event Posted(bytes32 indexed id, bytes32 indexed symbol, Kind kind, address poster);
    event Challenged(bytes32 indexed id, address challenger);
    event Finalized(bytes32 indexed id, bytes32 indexed symbol, uint256 index, bytes32 root, address poster);
    event Rejected(bytes32 indexed id, address challenger);
    event AttesterSet(bytes32 indexed symbol, address attester);

    // ---- errors ----
    error NoAttester(bytes32 symbol);
    error BadSignature();
    error WrongBond(uint256 expected, uint256 got);
    error NotPending(bytes32 id);
    error WindowOpen(uint64 until);
    error WindowClosed(uint64 at);
    error AlreadyPosted(bytes32 id);
    error NotReviewer();
    error TreeFull();
    error TransferFailed();
}
