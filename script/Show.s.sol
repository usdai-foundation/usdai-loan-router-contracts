// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract Show is Deployer {
    function run() public {
        console.log("Printing deployments\n");
        console.log("Network: %s\n", _chainIdToNetwork[block.chainid]);

        /* Deserialize */
        _deserialize();

        console.log("loanRouterV2:                  %s", _deployment.loanRouterV2);
        console.log("loanScheduleViewer:            %s", _deployment.loanScheduleViewer);
        console.log("collateralTimelock:            %s", _deployment.collateralTimelock);
        console.log("depositTimelock:               %s", _deployment.depositTimelock);
        console.log("escrowTimelock:                %s", _deployment.escrowTimelock);
        console.log("simpleInterestRateModel:       %s", _deployment.simpleInterestRateModel);
        console.log("amortizedInterestRateModel:    %s", _deployment.amortizedInterestRateModel);
        console.log("absoluteFeeModel:              %s", _deployment.absoluteFeeModel);
        console.log("ratioFeeModel:                 %s", _deployment.ratioFeeModel);
        console.log("reserveAccountBeacon:          %s", _deployment.reserveAccountBeacon);

        console.log("Printing deployments completed");
    }
}
