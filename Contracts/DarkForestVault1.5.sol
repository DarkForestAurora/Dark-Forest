pragma solidity 0.7.3;

import "../openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "../openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "../openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IController.sol";
import "../helpers/ControllableInit.sol";
import "./VaultStorage.sol";

contract DarkForestVault15 is ERC20Upgradeable, ControllableInit, VaultStorage {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    event Withdraw(address indexed beneficiary, uint256 amount);
    event Deposit(address indexed beneficiary, uint256 amount);
    event Invest(uint256 amount);

    constructor() public {}

    function initialize(
        address _storage,//governance address
        address _underlying//_want token
    ) public initializer {
        //creates new erc token for this vault
        __ERC20_init(
            string(abi.encodePacked("DF_", ERC20Upgradeable(_underlying).symbol())),
            string(abi.encodePacked("DF", ERC20Upgradeable(_underlying).symbol()))
        );
        _setupDecimals(ERC20Upgradeable(_underlying).decimals());
        //sets _storage as governance
        ControllableInit.initializeControllableInit(
            _storage
        );
        uint256 underlyingUnit = 10 ** uint256(ERC20Upgradeable(address(_underlying)).decimals());
        VaultStorage.initializeVaultStorage(
            _underlying,
            underlyingUnit
        );
    }
    //Accounts for ppl transferring receipt token
    // override erc20 transfer function
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        super._transfer(sender, recipient, amount);
        IStrategy(strategy()).updateUserRewardDebts(sender);
        IStrategy(strategy()).updateUserRewardDebts(recipient);
    }
    //Strategy deployed along side this vault
    function strategy() public view returns(address) {
        return _strategy();
    }
    //underlying LP
    function underlying() public view returns(address) {
        return _underlying();
    }
    //units of LP
    function underlyingUnit() public view returns(uint256) {
        return _underlyingUnit();
    }
    //Ensures strategy is defined before calling fxns
    modifier whenStrategyDefined() {
        require(address(strategy()) != address(0), "undefined strategy");
        _;
    }
    //Change strategy
    function setStrategy(address _strategy) public onlyControllerOrGovernance {
        require(_strategy != address(0), "empty strategy");
        require(IStrategy(_strategy).underlying() == address(underlying()), "underlying not match");
        require(IStrategy(_strategy).vault() == address(this), "strategy vault not match");

        _setStrategy(_strategy);
        IERC20Upgradeable(underlying()).safeApprove(address(strategy()), 0);
        IERC20Upgradeable(underlying()).safeApprove(address(strategy()), uint256(~0));
    }

    // Only smart contracts will be affected by this modifier
    modifier defense() {
        require(
            (msg.sender == tx.origin) ||                // If it is a normal user and not smart contract,
            // then the requirement will pass
            !IController(controller()).greyList(msg.sender), // If it is a smart contract, then
            "grey listed"  // make sure that it is not on our greyList.
        );
        _;
    }
    //Step 1: transfer tokens in vault contract(this) to strategy
    function stakeTriFarm() whenStrategyDefined onlyControllerOrGovernance external {
        invest();
        IStrategy(strategy()).stakeTriFarm();
    }
    //Step 2: stake xTri
    function stakeXTri() whenStrategyDefined onlyControllerOrGovernance external {
        IStrategy(strategy()).stakeXTri();
    }
    
    //Step 3: stake xTri for more Tri
    function stakeExternalRewards() whenStrategyDefined onlyControllerOrGovernance external {
        IStrategy(strategy()).stakeExternalRewards();
    }

    //how much tokens the vault contract has
    function underlyingBalanceInVault() view public returns (uint256) {
        return IERC20Upgradeable(underlying()).balanceOf(address(this));
    }
    //Amount staked by userS(vault+strategy)
    function underlyingBalanceWithInvestment() view public returns (uint256) {
        if (address(strategy()) == address(0)) {
            // initial state, when not set
            return underlyingBalanceInVault();
        }
        return underlyingBalanceInVault().add(IStrategy(strategy()).investedUnderlyingBalance());
    }
    //Amount staked by user
    function underlyingBalanceWithInvestmentForHolder(address holder) view external returns (uint256) {
        if (totalSupply() == 0) {
            return 0;
        }
        return underlyingBalanceWithInvestment()
        .mul(balanceOf(holder))
        .div(totalSupply());
    }

    function rebalance() external onlyControllerOrGovernance {
        withdrawAll();
        invest();
    }

    function invest() internal whenStrategyDefined {
        uint256 availableAmount = underlyingBalanceInVault();
        if (availableAmount > 0) {
            IERC20Upgradeable(underlying()).safeTransfer(address(strategy()), availableAmount);
            emit Invest(availableAmount);
        }
    }
    //Deposit
    function deposit(uint256 amount) external defense {
        _deposit(amount, msg.sender, msg.sender);
    }
    //Deposit for another
    function depositFor(uint256 amount, address holder) public defense {
        _deposit(amount, msg.sender, holder);
    }
    //Withdraw from masterchef to strat to pool
    function withdrawAll() public onlyControllerOrGovernance whenStrategyDefined {
        IStrategy(strategy()).withdrawAllToVault();
    }

    function withdraw(uint256 numberOfShares) external {
        require(totalSupply() > 0, "no shares");
        IStrategy(strategy()).updateAccPerShare(msg.sender);
        //sends rewards(xTRI) to users. To only withdraw rewards, withdraw(0) will be called
        IStrategy(strategy()).withdrawReward(msg.sender);

        if (numberOfShares > 0) {
            uint256 totalSupply = totalSupply();
            _burn(msg.sender, numberOfShares);

            uint256 underlyingAmountToWithdraw = underlyingBalanceWithInvestment()
            .mul(numberOfShares)
            .div(totalSupply);
            if (underlyingAmountToWithdraw > underlyingBalanceInVault()) {
                // withdraw everything from the strategy to accurately check the share value
                if (numberOfShares == totalSupply) {
                    IStrategy(strategy()).withdrawAllToVault();
                } else {
                    uint256 missing = underlyingAmountToWithdraw.sub(underlyingBalanceInVault());
                    IStrategy(strategy()).withdrawToVault(missing);
                }
                // recalculate to improve accuracy
                underlyingAmountToWithdraw = MathUpgradeable.min(underlyingBalanceWithInvestment()
                    .mul(numberOfShares)
                    .div(totalSupply), underlyingBalanceInVault());
            }

            // Send withdrawal fee  0.1%
            if (address(strategy()) != address(0)) {
                uint256 feeAmount = underlyingAmountToWithdraw.mul(10).div(10000);
                IERC20Upgradeable(underlying()).safeTransfer(IStrategy(strategy()).treasury(), feeAmount);
                underlyingAmountToWithdraw = underlyingAmountToWithdraw.sub(feeAmount);
            }

            IERC20Upgradeable(underlying()).safeTransfer(msg.sender, underlyingAmountToWithdraw);

            // update the withdrawal amount for the holder
            emit Withdraw(msg.sender, underlyingAmountToWithdraw);
        }

        IStrategy(strategy()).updateUserRewardDebts(msg.sender);
    }

    function _deposit(uint256 amount, address sender, address beneficiary) internal {
        require(beneficiary != address(0), "holder undefined");
        IStrategy(strategy()).updateAccPerShare(beneficiary);
        IStrategy(strategy()).withdrawReward(beneficiary);

        if (amount > 0) {
            uint256 toMint = totalSupply() == 0
            ? amount
            : amount.mul(totalSupply()).div(underlyingBalanceWithInvestment());
            _mint(beneficiary, toMint);

            IERC20Upgradeable(underlying()).safeTransferFrom(sender, address(this), amount);

            // update the contribution amount for the beneficiary
            emit Deposit(beneficiary, amount);
        }
        IStrategy(strategy()).updateUserRewardDebts(beneficiary);
    }
}