pragma solidity 0.7.3;

import "./AlphaStrategyAurora.sol";

contract StrategyAdapterAurora is AlphaStrategyAurora {
    constructor() public {}

    function initialize(
        address _multisigWallet,
        address _rewardManager,
        address _vault,
        address _underlying,
        uint256 _poolId
        //uint256 _xTriStakingPoolId,
        //address _xTriRewardsToken
    ) public initializer {
        AlphaStrategyAurora.initializeAlphaStrategy(
            _multisigWallet,
            _rewardManager,
            _underlying,
            _vault,
            address(0x2B2e72C232685fC4D350Eaa92f39f6f8AD2e1593), // Tri masterchef//WANNA MC
            _poolId,
            address(0x7faA64Faf54750a2E3eE621166635fEAF406Ab22), // Tri //WANNA
            address(0x5205c30bf2E37494F8cF77D2c19C6BA4d2778B9B) // xTri  //WANNAX
            //address(0x2B2e72C232685fC4D350Eaa92f39f6f8AD2e1593) // xTriFarmingMasterchef// WANNA MC
            //_xTriStakingPoolId // 11
        );
    }
}