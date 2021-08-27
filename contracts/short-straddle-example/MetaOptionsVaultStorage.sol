// SPDX-License-Identifier: MIT
pragma solidity >=0.7.2;

import {IRibbonVault} from "../V2/interfaces/IRibbonVault.sol";

abstract contract OptionsMetaVaultStorageV1 {
    // INSERT STORAGE VARIABLES HERE
    IRibbonVault public putSellingVault;
    IRibbonVault public callSellingVault;
}

// We are following Compound's method of upgrading new contract implementations
// When we need to add new storage variables, we create a new version of OptionsVaultStorage
// e.g. OptionsVaultStorageV<versionNumber>, so finally it would look like
// contract OptionsVaultStorage is OptionsVaultStorageV1, OptionsVaultStorageV2
abstract contract OptionsMetaVaultStorage is OptionsMetaVaultStorageV1 {

}
