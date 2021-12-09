// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultLifecycle} from "../V2/libraries/VaultLifecycle.sol";
import {Vault} from "../V2/libraries/Vault.sol";
import {ShareMath} from "../V2/libraries/ShareMath.sol";

import {IRibbonVault} from "../V2/interfaces/IRibbonVault.sol";
import {IOptionsVault} from "../V2/interfaces/IOptionsVault.sol";
import {RibbonVaultBase} from "../V2/base/RibbonVaultBase.sol";

import "hardhat/console.sol";

contract RibbonDCAVault is RibbonVaultBase {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using ShareMath for Vault.DepositReceipt;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    address public immutable USDC;

    IOptionsVault public putSellingVault;
    IRibbonVault public callSellingVault;

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     * @param _usdc is the USDC contract
     */
    constructor(address _weth, address _usdc) RibbonVaultBase(_weth) {
        require(_usdc != address(0), "!_usdc");
        USDC = _usdc;
    }

    /**
     * @notice Initializes the OptionVault contract with storage variables.
     * @param _owner is the owner of the vault with critical permissions
     * @param _feeRecipient is the address to recieve vault performance and management fees
     * @param _managementFee is the management fee pct.
     * @param _performanceFee is the perfomance fee pct.
     * @param _tokenName is the name of the token
     * @param _tokenSymbol is the symbol of the token
     * @param _putSellingVault is the address of the put selling vault
     * @param _callSellingVault is the address of the call selling vault
     * @param _vaultParams is the struct with vault general data
     */
    function initialize(
        address _owner,
        address _keeper,
        address _feeRecipient,
        uint256 _managementFee,
        uint256 _performanceFee,
        string memory _tokenName,
        string memory _tokenSymbol,
        address _putSellingVault,
        address _callSellingVault,
        Vault.VaultParams calldata _vaultParams
    ) external initializer {
        baseInitialize(
            _owner,
            _keeper,
            _feeRecipient,
            _managementFee,
            _performanceFee,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );

        require(_putSellingVault != address(0), "!_putSellingVault");
        require(_callSellingVault != address(0), "!_callSellingVault");
        require(
            IOptionsVault(_putSellingVault).asset() == _vaultParams.asset,
            "!_vaultParams.asset"
        );

        putSellingVault = IOptionsVault(_putSellingVault);
        callSellingVault = IRibbonVault(_callSellingVault);
    }

    /**
     * @notice Initiates a withdrawal that can be processed once the round completes
     * @param shares is the number of shares to withdraw
     */
    function initiateWithdraw(uint256 shares) public override {
        super.initiateWithdraw(shares);
        uint256 putSellingVaultShares = shares
            .mul(putSellingVault.balanceOf(address(this)))
            .div(totalSupply());
        putSellingVault.withdraw(putSellingVaultShares);
    }

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     */
    function completeWithdraw() public override {
        super.completeWithdraw();
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /*
     * @notice Helper function that performs most administrative tasks
     * such as setting next option, minting new shares, getting vault fees, etc.
     * @return lockedBalance is the new balance used to calculate next option purchase size or collateral size
     */
    function _rollVault() internal returns (uint256) {
        (
            uint256 _lockedBalance,
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
        uint256 lockedBalance = _lockedBalance.sub(
            _collectVaultFees(_lockedBalance)
        );

        vaultState.totalPending = 0;
        vaultState.round = uint16(currentRound + 1);

        _mint(address(this), mintShares);

        return lockedBalance;
    }

    /*
     * @notice Helper function that transfers management fees and performance fees from previous round.
     * @param pastWeekBalance is the balance we are about to lock for next round
     * @return vaultFee is the fee deducted
     */
    function _collectVaultFees(uint256 pastWeekBalance)
        internal
        returns (uint256)
    {
        (uint256 performanceFeeInAsset, , uint256 vaultFee) = VaultLifecycle
            .getVaultFees(
                vaultState,
                pastWeekBalance,
                performanceFee,
                managementFee
            );

        if (vaultFee > 0) {
            transferAsset(payable(feeRecipient), vaultFee);
            emit CollectVaultFees(
                performanceFeeInAsset,
                vaultFee,
                vaultState.round,
                feeRecipient
            );
        }

        return vaultFee;
    }

    /**
     * @notice Rolls the vault's funds into a new position.
     */
    function rollVault() external override onlyKeeper nonReentrant {
        uint256 totalPending = vaultState.totalPending;
        uint256 lockedBalance = _rollVault();

        vaultState.lockedAmount = uint104(lockedBalance);

        // TODO: REQUIRE ROLLING BEFORE UNDERLYING VAULTS
        // TODO: CONVERT SOME USDC TO ETH FOR COVERED CALL VAULT (using uni / sushi / etc)
        // TODO: DEPOSIT NEW FUNDS INTO VAULTS
        IERC20(vaultParams.asset).safeApprove(
            address(putSellingVault),
            totalPending
        );
        putSellingVault.deposit(totalPending);
    }

    /************************************************
     *  GETTERS
     ***********************************************/

    /**
     * @notice Returns the vault's total balance, including the amounts locked into a short position
     * @return total balance of the vault, including the amounts locked in third party protocols
     */
    function totalBalance() public view override returns (uint256) {
        return
            uint256(vaultState.lockedAmount).add(
                IERC20(vaultParams.asset).balanceOf(address(this))
            );
    }
}
