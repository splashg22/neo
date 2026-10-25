// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAllowlist} from "../interfaces/IAllowlist.sol";

/// @dev Local-chain stand-in for an eligibility registry. Anyone can set; not for production.
contract MockAllowlist is IAllowlist {
    mapping(address => bool) public allowed;

    /// @notice Allow or disallow an account.
    function set(address account, bool ok) external {
        allowed[account] = ok;
    }

    /// @inheritdoc IAllowlist
    function isAllowed(address account) external view returns (bool) {
        return allowed[account];
    }
}
