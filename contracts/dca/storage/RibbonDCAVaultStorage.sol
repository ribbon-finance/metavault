// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import {IRibbonVault} from "../../V2/interfaces/IRibbonVault.sol";
import {IOptionsVault} from "../../V2/interfaces/IOptionsVault.sol";

abstract contract RibbonDCAVaultStorageV1 {
    // Ribbon V1 vault to earn yield in
    IOptionsVault public yieldVault;
    // Ribbon V2 vault to DCA accrued yield into
    IRibbonVault public dcaVault;
}

// We are following Compound's method of upgrading new contract implementations
// When we need to add new storage variables, we create a new version of RibbonDCAVaultStorage
// e.g. RibbonDCAVaultStorage<versionNumber>, so finally it would look like
// contract RibbonDCAVaultStorage is RibbonDCAVaultStorageV1, RibbonDCAVaultStorageV2
abstract contract RibbonDCAVaultStorage is RibbonDCAVaultStorageV1 {

}
