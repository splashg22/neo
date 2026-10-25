// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAllowlist — who may trade or provide liquidity in a gated pool
/// @notice Implemented by whatever eligibility registry the issuer runs (KYC, accredited
///         investors, jurisdiction). The hook only asks yes/no.
interface IAllowlist {
    /// @return true when `account` may interact with gated pools
    function isAllowed(address account) external view returns (bool);
}
