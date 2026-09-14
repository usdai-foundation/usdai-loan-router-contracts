// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LoanScheduleViewer} from "src/LoanScheduleViewer.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployLoanScheduleViewer is Deployer {
    function run(
        address deployer
    ) public broadcast useDeployment returns (address) {
        if (_deployment.loanRouterV2 == address(0x0)) revert MissingDependency();

        // Deploy LoanScheduleViewer implementation
        LoanScheduleViewer viewerImpl = new LoanScheduleViewer(_deployment.loanRouterV2);
        console.log("LoanScheduleViewer implementation", address(viewerImpl));

        // Deploy LoanScheduleViewer proxy
        TransparentUpgradeableProxy viewer = new TransparentUpgradeableProxy(
            address(viewerImpl), deployer, abi.encodeWithSelector(LoanScheduleViewer.initialize.selector)
        );
        console.log("LoanScheduleViewer proxy", address(viewer));

        _deployment.loanScheduleViewer = address(viewer);

        return (address(viewer));
    }
}
