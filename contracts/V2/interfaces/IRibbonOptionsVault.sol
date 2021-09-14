// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;
pragma experimental ABIEncoderV2;

contract IRibbonOptionsVault {
    function nextOptionReadyAt() external view returns (uint256) {}

    function currentOption() external view returns (address) {}

    function nextOption() external view returns (address) {}
}
