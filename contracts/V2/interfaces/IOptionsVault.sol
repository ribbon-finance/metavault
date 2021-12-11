// SPDX-License-Identifier: MIT
pragma solidity >=0.7.2;

interface IOptionsVault {
    function deposit(uint256 amount) external;

    function withdraw(uint256 shares) external;

    function asset() external returns (address);

    function balanceOf(address user) external returns (uint256);

    function totalSupply() external returns (uint256);

    function instantWithdrawalFee() external view returns (uint256);

    function maxWithdrawableShares() external view returns (uint256);

    function accountVaultBalance(address account)
        external
        view
        returns (uint256);
}
