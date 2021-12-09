// SPDX-License-Identifier: MIT
pragma solidity >=0.7.2;

interface IOptionsVault {
    function deposit(uint256 amount) external;

    function withdraw(uint256 shares) external;

    function asset() external returns (address);

    function balanceOf(address user) external returns (uint256);
}
