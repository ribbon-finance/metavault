// SPDX-License-Identifier: MIT
pragma solidity ^0.7.3;
pragma experimental ABIEncoderV2;

contract IRibbonVaultBase {
    /*
     * @notice Performs most administrative tasks
     * such as setting next option, minting new shares, getting vault fees, etc.
     * @return newOption is the new option address
     * @return lockedBalance is the new balance used to calculate next option purchase size or collateral size
     */
    function rollVault() external virtual {}

    /**
     * @notice Returns the vault's total balance, including the amounts locked into a short position
     * @return total balance of the vault, including the amounts locked in third party protocols
     */
    function totalBalance() external view virtual returns (uint256) {}
}
