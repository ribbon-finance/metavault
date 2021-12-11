// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SignedSafeMath} from "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultLifecycle} from "../V2/libraries/VaultLifecycle.sol";
import {Vault} from "../V2/libraries/Vault.sol";
import {ShareMath} from "../V2/libraries/ShareMath.sol";

import {IRibbonVault} from "../V2/interfaces/IRibbonVault.sol";
import {IOptionsVault} from "../V2/interfaces/IOptionsVault.sol";
import {IWETH} from "../V2/interfaces/IWETH.sol";
import {RibbonVaultBase} from "../V2/base/RibbonVaultBase.sol";
import {RibbonDCAVaultStorage} from "./storage/RibbonDCAVaultStorage.sol";

contract RibbonDCAVault is RibbonVaultBase, RibbonDCAVaultStorage {
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SignedSafeMath for int256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;
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

    // The precision for distributing tokens to share holders
    uint256 public constant MAGNITUDE = 2**128;

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
     * @param _swapPath is the path for swapping
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
     * @param numShares is the number of shares to withdraw
     */
    function initiateWithdraw(uint256 numShares) public override {
        require(numShares > 0, "!numShares");

        // We do a max redeem before initiating a withdrawal
        // But we check if they must first have unredeemed shares
        if (
            depositReceipts[msg.sender].amount > 0 ||
            depositReceipts[msg.sender].unredeemedShares > 0
        ) {
            _redeem(0, true);
        }

        // Calculate shares to withdraw from the dca vault
        uint256 shareBalance = balanceOf(msg.sender);
        uint256 dcaWithdrawShares = shareBalance > 0
            ? dividendOf(msg.sender).mul(numShares).div(shareBalance)
            : 0;
        if (dcaWithdrawShares > 0) {
            // Initiate withdrawal from the dcaVault
            dcaVault.initiateWithdraw(uint128(dcaWithdrawShares));
            dcaVaultWithdrawals[msg.sender] = dcaVaultWithdrawals[msg.sender]
                .add(dcaWithdrawShares);
        }

        // This caches the `round` variable used in shareBalances
        uint256 currentRound = vaultState.round;
        Vault.Withdrawal storage withdrawal = withdrawals[msg.sender];

        bool withdrawalIsSameRound = withdrawal.round == currentRound;

        emit InitiateWithdraw(msg.sender, numShares, currentRound);

        uint256 existingShares = uint256(withdrawal.shares);

        uint256 withdrawalShares;
        if (withdrawalIsSameRound) {
            withdrawalShares = existingShares.add(numShares);
        } else {
            require(existingShares == 0, "Existing withdraw");
            withdrawalShares = numShares;
            withdrawals[msg.sender].round = uint16(currentRound);
        }

        ShareMath.assertUint128(withdrawalShares);
        withdrawals[msg.sender].shares = uint128(withdrawalShares);

        uint256 newQueuedWithdrawShares = uint256(
            vaultState.queuedWithdrawShares
        ).add(numShares);
        ShareMath.assertUint128(newQueuedWithdrawShares);
        vaultState.queuedWithdrawShares = uint128(newQueuedWithdrawShares);

        _transfer(msg.sender, address(this), numShares);
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

        // Calculate yield vault shares belonging to the user
        uint256 putSellingVaultShares = withdrawalShares
            .mul(yieldVault.balanceOf(address(this)))
            .div(totalSupply());
        uint256 assetBalance = IERC20(vaultParams.asset).balanceOf(
            address(this)
        );
        // Withdraw shares belonging to the user from the yield vault
        yieldVault.withdraw(putSellingVaultShares);
        uint256 withdrawAmount = IERC20(vaultParams.asset).balanceOf(
            address(this)
        ) - assetBalance;

        emit Withdraw(msg.sender, withdrawAmount, withdrawalShares);

        _burn(address(this), withdrawalShares);

        require(withdrawAmount > 0, "!withdrawAmount");
        transferAsset(msg.sender, withdrawAmount);

        _withdrawVaultAssets();
    }

    /**
     * @notice Rolls the vault's funds into a new position.
     */
    function rollVault() external override onlyKeeper nonReentrant {
        vaultState.lastLockedAmount = vaultState.lockedAmount;
        uint256 totalPending = vaultState.totalPending;
        (uint256 lockedBalance, uint256 withdrawnAmount) = _rollVault();
        // Swap and deposit yield vault profits into the dca vault
        _swapAndDeposit(withdrawnAmount, 0);

        vaultState.lockedAmount = uint104(lockedBalance);

        // Deposit pending deposits into the yield vault
        IERC20(vaultParams.asset).safeApprove(
            address(yieldVault),
            totalPending
        );
        yieldVault.deposit(totalPending);
    }

    /**
     * @notice Withdraws assets from the DCA Vault and transfers them to the sender
     */
    function _withdrawVaultAssets() internal {
        (, uint128 dcaShares) = dcaVault.withdrawals(msg.sender);
        uint256 dcaVaultWithdrawal = dcaVaultWithdrawals[msg.sender];
        dcaVaultWithdrawals[msg.sender] = 0;
        if (dcaShares > 0 && dcaVaultWithdrawal > 0) {
            // Complete the withdrawal from the DCA Vault
            uint256 dcaAssetBalance;
            if (dcaVaultAsset == WETH) {
                dcaAssetBalance = address(this).balance;
                dcaVault.completeWithdraw();
                dcaAssetBalance = address(this).balance - dcaAssetBalance;
                IWETH(WETH).deposit{value: dcaAssetBalance}();
            } else {
                dcaAssetBalance = IERC20(dcaVaultAsset).balanceOf(
                    address(this)
                );
                dcaVault.completeWithdraw();
                dcaAssetBalance =
                    IERC20(dcaVaultAsset).balanceOf(address(this)) -
                    dcaAssetBalance;
            }
            if (dcaAssetBalance > 0) {
                // Transfer withdrawn assets to the user
                uint256 userAssets = dcaVaultWithdrawal
                    .mul(dcaAssetBalance)
                    .div(dcaShares);
                transferAsset(msg.sender, userAssets);
                uint256 remainingAssets = dcaAssetBalance.sub(userAssets);
                if (remainingAssets > 0) {
                    // Redeposit any extra amounts withdrawn
                    IERC20(dcaVaultAsset).safeApprove(
                        address(dcaVault),
                        remainingAssets
                    );
                    dcaVault.deposit(remainingAssets);
                }
            }
        }
    }

    /**
     * @notice Helper function that performs most administrative tasks
     * such as setting next option, minting new shares, getting vault fees, etc.
     * @return lockedBalance is the new balance used to calculate next option purchase size or collateral size
     * @return withdrawnAmount amount of profits withdrawn from the vault to DCA
     */
    function _rollVault() internal returns (uint256, uint256) {
        (uint256 accountVaultBalance, ) = yieldVault.withdrawAmountWithShares(
            yieldVault.balanceOf(address(this))
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

        // Withdraw profits from yield vault
        uint256 withdrawnAmount = _withdrawProfits(
            accountVaultBalance,
            vaultState.lastLockedAmount
        );

        // Take management / performance fee from previous round and deduct
        uint256 lockedBalance = _lockedBalance.sub(
            _collectVaultFees(_lockedBalance)
        );

        vaultState.totalPending = 0;
        vaultState.round = uint16(currentRound + 1);

        _mint(address(this), mintShares);

        return (lockedBalance, withdrawnAmount);
    }

    /**
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
     * @notice Withdraws any profits from the yield vault
     * @param accountVaultBalance The current balance in the vault
     * @param lastLockedAmount Amount that was locked in the yield vault in the previous round
     * @return withdrawnAmount Amount of the asset withdrawn from the yield vault
     */
    function _withdrawProfits(
        uint256 accountVaultBalance,
        uint256 lastLockedAmount
    ) internal returns (uint256 withdrawnAmount) {
        if (accountVaultBalance > lastLockedAmount) {
            // Calculate yield vault profit in terms of shares
            uint256 withdrawShares = (accountVaultBalance.sub(lastLockedAmount))
                .mul(yieldVault.balanceOf(address(this)))
                .div(yieldVault.totalSupply());
            uint256 withdrawableShares = Math.min(
                withdrawShares,
                yieldVault.maxWithdrawableShares()
            );
            if (withdrawableShares > 0) {
                uint256 assetBalance = IERC20(vaultParams.asset).balanceOf(
                    address(this)
                );
                // Withdraw shares from the yield vault
                yieldVault.withdraw(withdrawableShares);
                withdrawnAmount =
                    IERC20(vaultParams.asset).balanceOf(address(this)) -
                    assetBalance;
            }
        }
    }

    /**
     * @notice Swaps profits and deposits into the dca vault
     * @param withdrawnAmount Amount of the asset withdrawn from the yield vault
     * @param minAmountOut Amount to receive after swapping the withdrawn amount
     * @return receivedAmount Amount received
     */
    function _swapAndDeposit(uint256 withdrawnAmount, uint256 minAmountOut)
        internal
        returns (uint256 receivedAmount)
    {
        // Swap asset to the dca vault asset
        receivedAmount = VaultLifecycle.swap(
            vaultParams.asset,
            withdrawnAmount,
            minAmountOut,
            UNISWAP_ROUTER,
            swapPath
        );
        if (receivedAmount > 0) {
            uint256 vaultShares = dcaVault.shares(address(this));
            // Deposit the dca vault asset into the dca vault
            IERC20(dcaVaultAsset).safeApprove(
                address(dcaVault),
                receivedAmount
            );
            dcaVault.deposit(receivedAmount);
            vaultShares = dcaVault.shares(address(this)) - vaultShares;
            // Distribute new vault shares as dividends to share holders
            magnifiedDividendPerShare = magnifiedDividendPerShare.add(
                (vaultShares).mul(MAGNITUDE) / totalSupply()
            );
        }
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        super._transfer(sender, recipient, amount);

        // Adjust dividend correction for sender and recipient
        if (magnifiedDividendPerShare != 0) {
            int256 dividendCorrectionDelta = magnifiedDividendPerShare
                .mul(amount)
                .toInt256();
            magnifiedDividendCorrections[sender] = magnifiedDividendCorrections[
                sender
            ].add(dividendCorrectionDelta);
            magnifiedDividendCorrections[
                recipient
            ] = magnifiedDividendCorrections[recipient].sub(
                dividendCorrectionDelta
            );
        }
    }

    function _mint(address account, uint256 amount) internal override {
        super._mint(account, amount);

        // Adjust dividend correction for account
        if (magnifiedDividendPerShare != 0) {
            magnifiedDividendCorrections[
                account
            ] = magnifiedDividendCorrections[account].sub(
                (magnifiedDividendPerShare.mul(amount)).toInt256()
            );
        }
    }

    function _burn(address account, uint256 amount) internal override {
        super._burn(account, amount);

        // Adjust dividend correction for account
        if (magnifiedDividendPerShare != 0) {
            magnifiedDividendCorrections[
                account
            ] = magnifiedDividendCorrections[account].add(
                (magnifiedDividendPerShare.mul(amount)).toInt256()
            );
        }
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

    /**
     * @notice Returns the dca vault shares that belong to the account
     * @param account Account address
     * @return Dca vault shares owned by the account
     */
    function dividendOf(address account) public view returns (uint256) {
        // (magnifiedDividendPerShare * balanceOf(account) + magnifiedDividendCorrections[account]) / magnitude
        return
            magnifiedDividendPerShare
                .mul(shares(account))
                .toInt256()
                .add(magnifiedDividendCorrections[account])
                .toUint256() / MAGNITUDE;
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
