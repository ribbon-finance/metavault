// SPDX-License-Identifier: MIT
pragma solidity ^0.7.3;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import {VaultLifecycle} from "../V2/libraries/VaultLifecycle.sol";
import {Vault} from "../V2/libraries/Vault.sol";
import {ShareMath} from "../V2/libraries/ShareMath.sol";

import {IRibbonVault} from "../V2/interfaces/IRibbonVault.sol";
import {IRibbonOptionsVault} from "../V2/interfaces/IRibbonOptionsVault.sol";
import {RibbonVaultBase} from "../V2/base/RibbonVaultBase.sol";

contract RibbonStraddleVault is RibbonVaultBase {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using ShareMath for Vault.DepositReceipt;

    event CollectVaultFees(
        uint256 performanceFee,
        uint256 vaultFee,
        uint256 round
    );
    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    address public immutable USDC;

    IRibbonVault public putSellingVault;
    IRibbonVault public callSellingVault;

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     * @param _usdc is the USDC contract
     */
    constructor(address _weth, address _usdc) {
        require(_weth != address(0), "!_weth");
        require(_usdc != address(0), "!_usdc");

        WETH = _weth;
        USDC = _usdc;
    }

    /**
     * @notice Initializes the OptionVault contract with storage variables.
     */
    function initialize(
        address _owner,
        address _keeper,
        address _feeRecipient,
        uint256 _managementFee,
        uint256 _performanceFee,
        string memory tokenName,
        string memory tokenSymbol,
        address _putSellingVault,
        address _callSellingVault,
        Vault.VaultParams calldata _vaultParams
    ) internal initializer {
        baseInitialize(
            _owner,
            _keeper,
            _feeRecipient,
            _managementFee,
            _performanceFee,
            tokenName,
            tokenSymbol,
            _vaultParams
        );

        require(_putSellingVault != address(0), "!_putSellingVault");
        require(_callSellingVault != address(0), "!_callSellingVault");

        putSellingVault = IRibbonVault(_putSellingVault);
        callSellingVault = IRibbonVault(_callSellingVault);
    }

    /**
     * @notice Initiates a withdrawal that can be processed once the round completes
     * @param shares is the number of shares to withdraw
     */
    function initiateWithdraw(uint128 shares) public override nonReentrant {
        uint128 sharesPerVault = uint128(uint256(shares).div(2));
        putSellingVault.initiateWithdraw(sharesPerVault);
        callSellingVault.initiateWithdraw(sharesPerVault);
        super.initiateWithdraw(shares);
    }

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     */
    function completeWithdraw() public override nonReentrant {
        // TODO: CONVERT BACK SOME ETH TO USDC IN CASE?
        putSellingVault.completeWithdraw();
        callSellingVault.completeWithdraw();
        super.completeWithdraw();
    }

    /**
     * @notice Withdraws the assets on the vault using the outstanding `DepositReceipt.amount`
     * @param amount is the amount to withdraw
     */
    function withdrawInstantly(uint256 amount) public override nonReentrant {
        require(
            depositReceipts[msg.sender].round == vaultState.round,
            "Invalid round"
        );
        super.withdrawInstantly(amount);
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /*
     * @notice Helper function that performs most administrative tasks
     * such as setting next option, minting new shares, getting vault fees, etc.
     * @return queuedWithdrawAmount is the queued amount for withdrawal
     */
    function _rollVault() internal returns (uint256) {
        (
            uint256 lockedBalance,
            uint256 queuedWithdrawAmount,
            uint256 newPricePerShare,
            uint256 mintShares
        ) = VaultLifecycle.rollover(
                totalSupply(),
                totalBalance(),
                vaultParams,
                vaultState
            );

        // Finalize the pricePerShare at the end of the round
        uint256 currentRound = vaultState.round;
        roundPricePerShare[currentRound] = newPricePerShare;

        // Take management / performance fee from previous round and deduct
        lockedBalance = lockedBalance.sub(_collectVaultFees(lockedBalance));

        vaultState.totalPending = 0;
        vaultState.round = uint16(currentRound + 1);
        vaultState.lockedAmount = uint104(lockedBalance);

        _mint(address(this), mintShares);

        return queuedWithdrawAmount;
    }

    /*
     * @notice Helper function that transfers management fees and performance fees from previous round.
     * @param currentLockedBalance is the balance we are about to lock for next round
     * @return vaultFee is the fee deducted
     */
    function _collectVaultFees(uint256 currentLockedBalance)
        internal
        returns (uint256)
    {
        // TODO: FIGURE OUT FEE COLLECTION
        // (funds will be both in eth and usdc for covered and put selling vaults respectively)

        (uint256 performanceFeeInAsset, , uint256 vaultFee) = VaultLifecycle
            .getVaultFees(
                vaultState,
                currentLockedBalance,
                performanceFee,
                managementFee
            );

        if (vaultFee > 0) {
            transferAsset(payable(feeRecipient), vaultFee);
            emit CollectVaultFees(
                performanceFeeInAsset,
                vaultFee,
                vaultState.round
            );
        }

        return vaultFee;
    }

    /**
     * @notice Rolls the vault's funds into a new position.
     */
    function rollVault() external override onlyKeeper nonReentrant {
        uint256 lockedBalance = _rollVault();

        vaultState.lockedAmount = uint104(lockedBalance);

        // TODO: REQUIRE ROLLING BEFORE UNDERLYING VAULTS
        // TODO: CONVERT SOME USDC TO ETH FOR COVERED CALL VAULT (using uni / sushi / etc)
        // TODO: DEPOSIT NEW FUNDS INTO VAULTS
    }

    /************************************************
     *  GETTERS
     ***********************************************/

    /**
     * @notice Returns the vault's total balance, including the amounts locked into a short position
     * @return total balance of the vault, including the amounts locked in third party protocols
     */
    function totalBalance() public view override returns (uint256) {
        // TODO: FIGURE OUT BALANCE OF VAULT (USDC + VAULT BALANCE IN BASE VAULTS)
        return 0;
    }

    // TODO: ADD MORE RELEVANT GETTERS?
}
