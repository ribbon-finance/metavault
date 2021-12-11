// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultLifecycle} from "../V2/libraries/VaultLifecycle.sol";
import {Vault} from "../V2/libraries/Vault.sol";
import {ShareMath} from "../V2/libraries/ShareMath.sol";

import {IRibbonVault} from "../V2/interfaces/IRibbonVault.sol";
import {IOptionsVault} from "../V2/interfaces/IOptionsVault.sol";
import {RibbonVaultBase} from "../V2/base/RibbonVaultBase.sol";
import {RibbonDCAVaultStorage} from "./storage/RibbonDCAVaultStorage.sol";

import "hardhat/console.sol";

contract RibbonDCAVault is RibbonVaultBase, RibbonDCAVaultStorage {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using ShareMath for Vault.DepositReceipt;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    // UNISWAP_ROUTER is the contract address of UniswapV3 Router which handles swaps
    // https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol
    address public immutable UNISWAP_ROUTER;

    // UNISWAP_FACTORY is the contract address of UniswapV3 Factory which stores pool information
    // https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/IUniswapV3Factory.sol
    address public immutable UNISWAP_FACTORY;

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     * @param _uniswapRouter is the contract address for UniswapV3 router which handles swaps
     * @param _uniswapFactory is the contract address for UniswapV3 factory
     */
    constructor(
        address _weth,
        address _uniswapRouter,
        address _uniswapFactory
    ) RibbonVaultBase(_weth) {
        require(_uniswapRouter != address(0), "!_uniswapRouter");
        require(_uniswapFactory != address(0), "!_uniswapFactory");

        UNISWAP_ROUTER = _uniswapRouter;
        UNISWAP_FACTORY = _uniswapFactory;
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
        bytes calldata _swapPath,
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

        yieldVault = IOptionsVault(_putSellingVault);
        dcaVault = IRibbonVault(_callSellingVault);
        (, , dcaVaultAsset, , , ) = IRibbonVault(_callSellingVault)
            .vaultParams();
        swapPath = _swapPath;

        require(_checkPath(_swapPath), "Invalid swapPath");
    }

    /************************************************
     *  SETTERS
     ***********************************************/

    /**
     * @notice Sets a new path for swaps
     * @param newSwapPath is the new path
     */
    function setSwapPath(bytes calldata newSwapPath)
        external
        onlyOwner
        nonReentrant
    {
        require(_checkPath(newSwapPath), "Invalid swapPath");
        swapPath = newSwapPath;
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /**
     * @notice Initiates a withdrawal that can be processed once the round completes
     * @param shares is the number of shares to withdraw
     */
    function initiateWithdraw(uint256 shares) public override {
        super.initiateWithdraw(shares);
    }

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     */
    function completeWithdraw() public override {
        Vault.Withdrawal storage withdrawal = withdrawals[msg.sender];

        uint256 withdrawalShares = withdrawal.shares;
        uint256 withdrawalRound = withdrawal.round;

        // This checks if there is a withdrawal
        require(withdrawalShares > 0, "Not initiated");

        require(withdrawalRound < vaultState.round, "Round not closed");

        // We leave the round number as non-zero to save on gas for subsequent writes
        withdrawals[msg.sender].shares = 0;
        vaultState.queuedWithdrawShares = uint128(
            uint256(vaultState.queuedWithdrawShares).sub(withdrawalShares)
        );

        uint256 putSellingVaultShares = withdrawalShares
            .mul(yieldVault.balanceOf(address(this)))
            .div(totalSupply());
        uint256 assetBalance = IERC20(vaultParams.asset).balanceOf(
            address(this)
        );
        yieldVault.withdraw(putSellingVaultShares);
        uint256 withdrawAmount = IERC20(vaultParams.asset).balanceOf(
            address(this)
        ) - assetBalance;

        emit Withdraw(msg.sender, withdrawAmount, withdrawalShares);

        _burn(address(this), withdrawalShares);

        require(withdrawAmount > 0, "!withdrawAmount");
        transferAsset(msg.sender, withdrawAmount);
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
        uint256 accountVaultBalance = yieldVault.accountVaultBalance(
            address(this)
        );
        (
            uint256 _lockedBalance,
            uint256 newPricePerShare,
            uint256 mintShares
        ) = VaultLifecycle.rollover(
                totalSupply(),
                accountVaultBalance.add(
                    IERC20(vaultParams.asset).balanceOf(address(this))
                ),
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

    function _withdrawProfits(
        uint256 accountVaultBalance,
        uint256 lastLockedAmount
    ) internal returns (uint256) {
        if (accountVaultBalance <= lastLockedAmount) {
            return 0;
        }
        uint256 withdrawShares = (accountVaultBalance.sub(lastLockedAmount))
            .mul(yieldVault.balanceOf(address(this)))
            .div(yieldVault.totalSupply());
        uint256 withdrawableShares = Math.min(
            withdrawShares,
            yieldVault.maxWithdrawableShares()
        );
        if (withdrawableShares == 0) {
            return 0;
        }
        uint256 assetBalance = IERC20(vaultParams.asset).balanceOf(
            address(this)
        );
        yieldVault.withdraw(withdrawableShares);
        uint256 withdrawAmount = IERC20(vaultParams.asset).balanceOf(
            address(this)
        ) - assetBalance;
        return withdrawAmount;
    }

    function _swapAndDeposit(uint256 withdrawAmount) internal {
        IERC20(vaultParams.asset).safeApprove(
            address(dcaVault),
            withdrawAmount
        );
        dcaVault.deposit(withdrawAmount);
    }

    /**
     * @notice Rolls the vault's funds into a new position.
     */
    function rollVault() external override onlyKeeper nonReentrant {
        vaultState.lastLockedAmount = vaultState.lockedAmount;
        uint256 totalPending = vaultState.totalPending;
        uint256 lockedBalance = _rollVault();

        vaultState.lockedAmount = uint104(lockedBalance);

        IERC20(vaultParams.asset).safeApprove(
            address(yieldVault),
            totalPending
        );
        yieldVault.deposit(totalPending);
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

    /************************************************
     *  HELPERS
     ***********************************************/

    /**
     * @notice Helper to check whether swap path goes from the yieldVaults underlying asset to the dcaVaults underlying asset
     * @param swapPath is the swap path e.g. encodePacked(tokenIn, poolFee, tokenOut)
     * @return boolean whether the path is valid
     */
    function _checkPath(bytes calldata swapPath) internal view returns (bool) {
        return
            VaultLifecycle.checkPath(
                swapPath,
                vaultParams.asset,
                dcaVaultAsset,
                UNISWAP_FACTORY
            );
    }
}
