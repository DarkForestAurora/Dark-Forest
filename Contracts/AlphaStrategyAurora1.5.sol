pragma solidity 0.7.3;

import "../openzeppelin/contracts/math/Math.sol";
import "../openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "../openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../openzeppelin/contracts/math/SafeMath.sol";
import "../openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interfaces/ITriBar.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IVault.sol";


contract AlphaStrategyAurora15 is OwnableUpgradeable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event RewardsWithdrawn(address indexed beneficiary, uint256 amount);
    event RewardsHarvested(uint256 amount);
    event LPDeposited(uint256 amount);
    event LPWithdrawn(uint256 amount);
    event curPendingXTriUpdate(uint256 amount);
    event PendingShare(address indexed beneficiary, uint256 amount);

    address public treasury;
    address public rewardManager;
    address public multisigWallet;

    mapping(address => uint256) public userXTriDebt;

    uint256 public accXTriPerShare;
    uint256 public lastPendingXTri;
    uint256 public curPendingXTri;

    uint256 keepFee;
    uint256 keepFeeMax;
    
    uint256 keepReward;
    uint256 keepRewardMax;
    
    address public vault;
    address public underlying;
    address public masterChef;
    address public Tri;
    address public xTri;

    address public xTriStakingMasterchef;
    uint256 public xTriStakingPoolId;

    bool public sell;
    uint256 public sellFloor;

    uint256 public poolId;

    constructor() public {
    }

    function initializeAlphaStrategy(
        address _multisigWallet,
        address _rewardManager,
        address _underlying,
        address _vault,
        address _masterChef,
        uint256 _poolId,
        address _Tri,
        address _xTri,
        address _xTriStakingMasterchef,
        uint _xTriStakingPoolId
    ) public initializer {
        underlying = _underlying;
        vault = _vault;
        masterChef = _masterChef;
        sell = true;
        poolId = _poolId;
        xTriStakingMasterchef = _xTriStakingMasterchef;
        xTriStakingPoolId = _xTriStakingPoolId;

        rewardManager = _rewardManager;

        __Ownable_init();

        address _lpt;
        (_lpt,,,) = IMasterChef(_masterChef).poolInfo(poolId);
        require(_lpt == underlying, "Pool Info does not match underlying");

        Tri = _Tri;
        xTri = _xTri;
        treasury = address(0xFF7122ea8Ef2FA9Be9464C29087cf6BADDF28c2F);
        //treasury
        keepFee = 3;
        keepFeeMax = 100;

        keepReward = 15;
        keepRewardMax = 100;


        multisigWallet = _multisigWallet;
    }

    // keep fee functions
    function setKeepFee(uint256 _fee, uint256 _feeMax) external onlyMultisigOrOwner {
        require(_feeMax > 0, "Treasury feeMax should be bigger than zero");
        require(_fee < _feeMax, "Treasury fee can't be bigger than feeMax");
        keepFee = _fee;
        keepFeeMax = _feeMax;
    }

    // keep reward functions
    function setKeepReward(uint256 _fee, uint256 _feeMax) external onlyMultisigOrOwner {
        require(_feeMax > 0, "Reward feeMax should be bigger than zero");
        require(_fee < _feeMax, "Reward fee can't be bigger than feeMax");
        keepReward = _fee;
        keepRewardMax = _feeMax;
    }

    // Salvage functions
    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == Tri || token == underlying);
    }

    /**
    * Salvages a token.
    */
    function salvage(address recipient, address token, uint256 amount) public onlyMultisigOrOwner {
        // To make sure that governance cannot come in and take away the coins
        require(!unsalvagableTokens(token), "token is defined as not salvagable");
        IERC20(token).safeTransfer(recipient, amount);
    }


    modifier onlyVault() {
        require(msg.sender == vault, "Not a vault");
        _;
    }

    modifier onlyMultisig() {
        require(msg.sender == multisigWallet , "The sender has to be the multisig wallet");
        _;
    }

    modifier onlyMultisigOrOwner() {
        require(msg.sender == multisigWallet || msg.sender == owner() , "The sender has to be the multisig wallet or owner");
        _;
    }

    function setMultisig(address _wallet) public onlyMultisig {
        multisigWallet = _wallet;
    }

    function updateAccPerShare(address user) public onlyVault {
        updateAccXTriPerShare(user);
    }
    
    function updateAccXTriPerShare(address user) internal {
        curPendingXTri = pendingXTri();

        if (lastPendingXTri > 0 && curPendingXTri < lastPendingXTri) {
            curPendingXTri = 0;
            lastPendingXTri = 0;
            accXTriPerShare = 0;
            userXTriDebt[user] = 0;
            return;
        }

        uint256 totalSupply = IERC20(vault).totalSupply();

        if (totalSupply == 0) {
            accXTriPerShare = 0;
            return;
        }

        uint256 addedReward = curPendingXTri.sub(lastPendingXTri);
        accXTriPerShare = accXTriPerShare.add(
            (addedReward.mul(1e36)).div(totalSupply)
        );
         //added
        lastPendingXTri = pendingXTri();
        emit curPendingXTriUpdate(accXTriPerShare);
    }

    function updateUserRewardDebts(address user) public onlyVault {
        userXTriDebt[user] = IERC20(vault).balanceOf(user)
            .mul(accXTriPerShare)
            .div(1e36);
    }

    function pendingXTri() public view returns (uint256) {
        uint256 xTriBalance = IERC20(xTri).balanceOf(address(this));
        return xTriMasterChefBalance().add(xTriBalance);
        return IERC20(xTri).balanceOf(address(this));
    }

    function pendingRewardOfUser(address user) external view returns (uint256) { //uint256) {
        return (pendingXTriOfUser(user));  
    }

   
    function pendingXTriOfUser(address user) public view returns (uint256) {
        uint256 totalSupply = IERC20(vault).totalSupply();
        uint256 userBalance = IERC20(vault).balanceOf(user);
        if (totalSupply == 0) return 0;

        // pending xTri
        uint256 allPendingXTri = pendingXTri();

        if (allPendingXTri < lastPendingXTri) return 0;

        uint256 addedReward = allPendingXTri.sub(lastPendingXTri);

        uint256 newAccXTriPerShare = accXTriPerShare.add(
            (addedReward.mul(1e36)).div(totalSupply)
        );

        uint256 _pendingXTri = userBalance.mul(newAccXTriPerShare).div(1e36).sub(
            userXTriDebt[user]
        );

        return _pendingXTri;
    }

    function getPendingShare(address user, uint256 perShare, uint256 debt) internal returns (uint256 share) {
        uint256 current = IERC20(vault).balanceOf(user)
            .mul(perShare)
            .div(1e36);

        if(current < debt){
            emit PendingShare(user, 0);
            return 0;
        }
        emit PendingShare(user, current.sub(debt));
        return current
            .sub(debt);
    }

    function withdrawReward(address user) public onlyVault {
        // withdraw pending xTri
        uint256 _pendingXTri = getPendingShare(user, accXTriPerShare, userXTriDebt[user]);

        uint256 _xTriBalance = IERC20(xTri).balanceOf(address(this));
        
        if(_xTriBalance < _pendingXTri){
            uint256 needToWithdraw = _pendingXTri.sub(_xTriBalance);
            uint256 toWithdraw = Math.min(xTriMasterChefBalance(), needToWithdraw);
            IMasterChef(xTriStakingMasterchef).withdraw(xTriStakingPoolId, toWithdraw);

            _xTriBalance = IERC20(xTri).balanceOf(address(this));
        }
        
        if (_xTriBalance < _pendingXTri) {
            _pendingXTri = _xTriBalance;
        }

        if(_pendingXTri > 0 && curPendingXTri > _pendingXTri){
            // send reward to user
            IERC20(xTri).safeTransfer(user, _pendingXTri);
            lastPendingXTri = curPendingXTri.sub(_pendingXTri);
            emit RewardsWithdrawn(user, _pendingXTri);
        }
    }
    /*
    *   Withdraws all the asset to the vault
    */
    function withdrawAllToVault() public onlyMultisigOrOwner {
        if (address(masterChef) != address(0)) {
            exitTriRewardPool();
        }
        IERC20(underlying).safeTransfer(vault, IERC20(underlying).balanceOf(address(this)));
        emit LPWithdrawn(IERC20(underlying).balanceOf(address(this)));
    }

    /*
    *   Withdraws all the asset to the vault
    */
    function withdrawToVault(uint256 amount) public onlyVault {
        // Typically there wouldn't be any amount here
        // however, it is possible because of the emergencyExit
        uint256 entireBalance = IERC20(underlying).balanceOf(address(this));

        if(amount > entireBalance){
            // While we have the check above, we still using SafeMath below
            // for the peace of mind (in case something gets changed in between)
            uint256 needToWithdraw = amount.sub(entireBalance);
            uint256 toWithdraw = Math.min(masterChefBalance(), needToWithdraw);
            IMasterChef(masterChef).withdraw(poolId, toWithdraw);
        }

        IERC20(underlying).safeTransfer(vault, amount);
        emit LPWithdrawn(amount);
    }

    /*
    *   Note that we currently do not have a mechanism here to include the
    *   amount of reward that is accrued.
    */
    function investedUnderlyingBalance() external view returns (uint256) {
        if (masterChef == address(0)) {
            return IERC20(underlying).balanceOf(address(this));
        }
        // Adding the amount locked in the reward pool and the amount that is somehow in this contract
        // both are in the units of "underlying"
        // The second part is needed because there is the emergency exit mechanism
        // which would break the assumption that all the funds are always inside of the reward pool
        return masterChefBalance().add(IERC20(underlying).balanceOf(address(this)));
    }

    // MasterChef Farm functions - LP reward pool functions

    function masterChefBalance() internal view returns (uint256 bal) {
        (bal,) = IMasterChef(masterChef).userInfo(poolId, address(this));
    }

    function exitTriRewardPool() internal {
        uint256 bal = masterChefBalance();
        if (bal != 0) {
            IMasterChef(masterChef).withdraw(poolId, bal);
        }
    }
    //edited to add claiming from xTri farm
    function claimTriRewardPool() internal {
        uint256 bal = masterChefBalance();
        if (bal != 0) {
            IMasterChef(masterChef).withdraw(poolId, 0);
        }

        uint256 balxTri = xTriMasterChefBalance();
        if (balxTri != 0) {
            IMasterChef(xTriStakingMasterchef).withdraw(xTriStakingPoolId, 0);
        }
        
    }
    
    function xTriMasterChefBalance() internal view returns (uint256 bal) {
        (bal,) = IMasterChef(xTriStakingMasterchef).userInfo(xTriStakingPoolId, address(this));
    }

    function exitRewardsForXTri() internal {
        uint256 bal = xTriMasterChefBalance();
    
        if (bal != 0) {
            IMasterChef(xTriStakingMasterchef).withdraw(xTriStakingPoolId, bal);
        }
    }
    
    function enterTriRewardPool() internal {
        uint256 entireBalance = IERC20(underlying).balanceOf(address(this));
        if (entireBalance != 0) {
            IERC20(underlying).safeApprove(masterChef, 0);
            IERC20(underlying).safeApprove(masterChef, entireBalance);
            IMasterChef(masterChef).deposit(poolId, entireBalance);
            emit LPDeposited(entireBalance);
        }
    }
    
    function enterXTriRewardPool() internal {
        uint256 entireBalance = IERC20(xTri).balanceOf(address(this));

        if (entireBalance != 0) {
            IERC20(xTri).safeApprove(xTriStakingMasterchef, 0);
            IERC20(xTri).safeApprove(xTriStakingMasterchef, entireBalance);

            IMasterChef(xTriStakingMasterchef).deposit(xTriStakingPoolId, entireBalance);
        }
    }
    
    function stakeTriFarm() external {
        enterTriRewardPool();
    }

    function stakeXTri() external {
        claimTriRewardPool();

        uint256 TriRewardBalance = IERC20(Tri).balanceOf(address(this));

        if (TriRewardBalance == 0) {
            return;
        }

        IERC20(Tri).safeApprove(xTri, 0);
        IERC20(Tri).safeApprove(xTri, TriRewardBalance);

        uint256 balanceBefore = IERC20(xTri).balanceOf(address(this));

        ITriBar(xTri).enter(TriRewardBalance);

        uint256 balanceAfter = IERC20(xTri).balanceOf(address(this));
        uint256 added = balanceAfter.sub(balanceBefore);

        if (added > 0) {
            uint256 fee = added.mul(keepFee).div(keepFeeMax);
            IERC20(xTri).safeTransfer(treasury, fee);
            
            uint256 feeReward = added.mul(keepReward).div(keepRewardMax);
            IERC20(xTri).safeTransfer(rewardManager, feeReward);
            emit RewardsHarvested(added.sub(fee).sub(feeReward));
        }
    }
    
    function stakeExternalRewards() external {
        enterXTriRewardPool();
    }

    function setXTriStakingPoolId(uint256 _poolId) public onlyMultisig {
        exitRewardsForXTri();

        xTriStakingPoolId = _poolId;

        enterXTriRewardPool();
    }
    
    function setTreasuryFundAddress(address _address) public onlyMultisigOrOwner {
        treasury = _address;
    }
    
    function setRewardManagerAddress(address _address) public onlyMultisigOrOwner {
        rewardManager = _address;
    }
    
}