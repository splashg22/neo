// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Tape} from "../src/Tape.sol";
import {ITape} from "../src/interfaces/ITape.sol";
import {IncrementalMerkle} from "../src/libraries/IncrementalMerkle.sol";

contract TapeTest is Test {
    Tape tape;

    address reviewer = makeAddr("reviewer");
    uint256 attesterKey = 0xA11CE;
    address attester;
    address poster = makeAddr("poster");
    address challenger = makeAddr("challenger");

    bytes32 constant ALFA = bytes32("ALFA");
    uint64 constant WINDOW = 1 days;
    uint256 constant POST_BOND = 0.1 ether;
    uint256 constant CHALLENGE_BOND = 0.2 ether;

    function setUp() public {
        attester = vm.addr(attesterKey);
        tape = new Tape(reviewer, WINDOW, POST_BOND, CHALLENGE_BOND);
        vm.prank(reviewer);
        tape.setAttester(ALFA, attester);
        vm.deal(poster, 10 ether);
        vm.deal(challenger, 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _ev(ITape.Kind kind, uint64 effective, uint256 value, uint64 nonce)
        internal
        pure
        returns (ITape.Event memory e)
    {
        e = ITape.Event({symbol: ALFA, kind: kind, effective: effective, value: value, nonce: nonce});
    }

    function _sign(ITape.Event memory e, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tape.digestOf(e));
        return abi.encodePacked(r, s, v);
    }

    function _post(ITape.Event memory e) internal returns (bytes32 id) {
        bytes memory sig = _sign(e, attesterKey); // before prank: digestOf is itself a call
        vm.prank(poster);
        id = tape.post{value: POST_BOND}(e, sig);
    }

    // ------------------------------------------------------------------ post

    function test_post_requiresAttesterSignature() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, uint64(vm.getBlockTimestamp() + 7 days), 40_000, 1);
        bytes memory badSig = _sign(e, 0xBAD);
        vm.prank(poster);
        vm.expectRevert(ITape.BadSignature.selector);
        tape.post{value: POST_BOND}(e, badSig);
    }

    function test_post_requiresBond() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, uint64(vm.getBlockTimestamp() + 7 days), 40_000, 1);
        bytes memory sig = _sign(e, attesterKey);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(ITape.WrongBond.selector, POST_BOND, 0));
        tape.post(e, sig);
    }

    function test_post_unknownSymbolReverts() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, 0, 40_000, 1);
        e.symbol = bytes32("NOPE");
        bytes memory sig = _sign(e, attesterKey);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(ITape.NoAttester.selector, bytes32("NOPE")));
        tape.post{value: POST_BOND}(e, sig);
    }

    function test_post_nonceReplayReverts() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, uint64(vm.getBlockTimestamp() + 7 days), 40_000, 1);
        _post(e);
        bytes memory sig = _sign(e, attesterKey);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(ITape.AlreadyPosted.selector, tape.leafOf(e)));
        tape.post{value: POST_BOND}(e, sig);
    }

    // ------------------------------------------------------------------ finalize

    function test_finalize_beforeWindowReverts() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, uint64(vm.getBlockTimestamp() + 7 days), 40_000, 1);
        bytes32 id = _post(e);
        vm.expectRevert(abi.encodeWithSelector(ITape.WindowOpen.selector, uint64(vm.getBlockTimestamp() + WINDOW)));
        tape.finalize(id);
    }

    function test_finalize_appliesSplitAndRefundsBond() public {
        uint64 eff = uint64(vm.getBlockTimestamp() + 7 days);
        ITape.Event memory e = _ev(ITape.Kind.Split, eff, 40_000, 1);
        bytes32 id = _post(e);
        uint256 before = poster.balance;

        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id);

        (ITape.Kind kind, uint64 effective, uint256 value) = tape.action(ALFA);
        assertEq(uint8(kind), uint8(ITape.Kind.Split));
        assertEq(effective, eff);
        assertEq(value, 40_000);
        assertEq(tape.eventCount(), 1);
        assertEq(poster.balance, before + POST_BOND);
    }

    function test_finalize_haltOnAndOff() public {
        ITape.Event memory on = _ev(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        bytes32 id1 = _post(on);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id1);
        assertTrue(tape.isHalted(ALFA));

        ITape.Event memory off = _ev(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 0, 2);
        bytes32 id2 = _post(off);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id2);
        assertFalse(tape.isHalted(ALFA));
        assertEq(tape.eventCount(), 2);
    }

    function test_finalize_twiceReverts() public {
        ITape.Event memory e = _ev(ITape.Kind.Dividend, uint64(vm.getBlockTimestamp()), 24, 1);
        bytes32 id = _post(e);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id);
        vm.expectRevert(abi.encodeWithSelector(ITape.NotPending.selector, id));
        tape.finalize(id);
    }

    // ------------------------------------------------------------------ challenge + resolve

    function test_challenge_afterWindowReverts() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, 0, 40_000, 1);
        bytes32 id = _post(e);
        uint64 closes = uint64(vm.getBlockTimestamp() + WINDOW);
        vm.warp(closes);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ITape.WindowClosed.selector, closes));
        tape.challenge{value: CHALLENGE_BOND}(id);
    }

    function test_challenge_blocksFinalize() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, 0, 40_000, 1);
        bytes32 id = _post(e);
        vm.prank(challenger);
        tape.challenge{value: CHALLENGE_BOND}(id);
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ITape.NotPending.selector, id));
        tape.finalize(id);
    }

    function test_resolve_rejected_paysChallenger() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, 0, 20_000, 1);
        bytes32 id = _post(e);
        vm.prank(challenger);
        tape.challenge{value: CHALLENGE_BOND}(id);
        uint256 before = challenger.balance;

        vm.prank(reviewer);
        tape.resolve(id, false);

        assertEq(challenger.balance, before + POST_BOND + CHALLENGE_BOND);
        (ITape.Kind kind,,) = tape.action(ALFA);
        assertEq(uint8(kind), uint8(ITape.Kind.None), "rejected event must not apply");
        assertEq(tape.eventCount(), 0);
    }

    function test_resolve_upheld_paysPosterAndApplies() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, 0, 40_000, 1);
        bytes32 id = _post(e);
        vm.prank(challenger);
        tape.challenge{value: CHALLENGE_BOND}(id);
        uint256 before = poster.balance;

        vm.prank(reviewer);
        tape.resolve(id, true);

        assertEq(poster.balance, before + POST_BOND + CHALLENGE_BOND);
        (ITape.Kind kind,, uint256 value) = tape.action(ALFA);
        assertEq(uint8(kind), uint8(ITape.Kind.Split));
        assertEq(value, 40_000);
        assertEq(tape.eventCount(), 1);
    }

    function test_resolve_onlyReviewer() public {
        ITape.Event memory e = _ev(ITape.Kind.Split, 0, 40_000, 1);
        bytes32 id = _post(e);
        vm.prank(challenger);
        tape.challenge{value: CHALLENGE_BOND}(id);
        vm.prank(poster);
        vm.expectRevert(ITape.NotReviewer.selector);
        tape.resolve(id, true);
    }

    // ------------------------------------------------------------------ merkle

    function test_merkle_rootAndProofForEveryLeaf() public {
        uint256 n = 7;
        bytes32[] memory leaves = new bytes32[](n);
        for (uint64 i = 0; i < n; i++) {
            ITape.Event memory e = _ev(ITape.Kind.Dividend, uint64(vm.getBlockTimestamp()), 10 + i, i + 1);
            leaves[i] = _post(e);
            vm.warp(vm.getBlockTimestamp() + WINDOW);
            tape.finalize(leaves[i]);
        }
        assertEq(tape.eventCount(), n);
        bytes32 root = tape.eventsRoot();
        assertEq(root, _referenceRoot(leaves), "on-chain root must match reference tree");

        for (uint256 i = 0; i < n; i++) {
            bytes32[] memory proof = _referenceProof(leaves, i);
            assertTrue(tape.verify(leaves[i], i, proof), "proof must verify");
            assertFalse(tape.verify(leaves[i], i ^ 1, proof), "wrong index must fail");
            bytes32 forged = keccak256(abi.encodePacked(leaves[i], "x"));
            assertFalse(tape.verify(forged, i, proof), "forged leaf must fail");
        }
    }

    /// @dev Full-tree reference: pad to 2^DEPTH with zero hashes and fold.
    function _referenceRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 depth = IncrementalMerkle.DEPTH;
        bytes32[] memory level = leaves;
        bytes32 zero = bytes32(0);
        for (uint256 d = 0; d < depth; d++) {
            uint256 next = (level.length + 1) / 2;
            bytes32[] memory up = new bytes32[](next);
            for (uint256 i = 0; i < next; i++) {
                bytes32 l = level[2 * i];
                bytes32 r = 2 * i + 1 < level.length ? level[2 * i + 1] : zero;
                up[i] = keccak256(abi.encodePacked(l, r));
            }
            zero = keccak256(abi.encodePacked(zero, zero));
            level = up;
        }
        return level[0];
    }

    function _referenceProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        uint256 depth = IncrementalMerkle.DEPTH;
        proof = new bytes32[](depth);
        bytes32[] memory level = leaves;
        bytes32 zero = bytes32(0);
        for (uint256 d = 0; d < depth; d++) {
            uint256 sib = index ^ 1;
            proof[d] = sib < level.length ? level[sib] : zero;
            uint256 next = (level.length + 1) / 2;
            bytes32[] memory up = new bytes32[](next);
            for (uint256 i = 0; i < next; i++) {
                bytes32 l = level[2 * i];
                bytes32 r = 2 * i + 1 < level.length ? level[2 * i + 1] : zero;
                up[i] = keccak256(abi.encodePacked(l, r));
            }
            zero = keccak256(abi.encodePacked(zero, zero));
            level = up;
            index >>= 1;
        }
    }
}
