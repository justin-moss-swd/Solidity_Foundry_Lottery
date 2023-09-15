//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployLottery} from "../../script/DeployLottery.s.sol";
import {Lottery} from "../../src/Lottery.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract LotteryTest is Test {
    /* Events */
    event EnteredLottery(address indexed player);

    Lottery lottery;
    HelperConfig helperConfig;

    uint256 entranceFee; 
    uint256 interval;
    address vrfCoordinator; 
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;
    uint256 deployerKey;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    
    function setUp() external {
        DeployLottery deployer = new DeployLottery();
        (lottery, helperConfig) = deployer.run();
        (
            entranceFee, 
            interval,
            vrfCoordinator, 
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,
            deployerKey
        ) = helperConfig.activeNetworkConfig();

        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testLotteryInitializesInOpenState() public view {
        assert(lottery.getLotteryState() == Lottery.LotteryState.OPEN);
    }

    // Enter Lottery
    function testLotteryRevertsWithNotEnoughEth() public {
        vm.prank(PLAYER);
        vm.expectRevert(Lottery.Lottery__NotEnoughEthSent.selector);
        lottery.enterLottery();
    }

    function testLotteryRecordsPlayerWhenEntered() public {
        vm.prank(PLAYER);
        lottery.enterLottery{ value: entranceFee}();
        address playerRecorded = lottery.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitsEventOnEntrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(lottery));
        emit EnteredLottery(PLAYER);
        lottery.enterLottery{ value: entranceFee}();
    }

    function testCantEnterWhenLotteryIsCalculating() public {
        vm.prank(PLAYER);
        lottery.enterLottery{ value: entranceFee}(); 
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        vm.expectRevert(Lottery.Lottery__LotteryNotOpen.selector);
        vm.prank(PLAYER);
        lottery.enterLottery{ value: entranceFee }();
    }

    // Check Upkeep
    function testCheckUpkeepIfNoBalance() public {
        // Arrange
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number +1);

        // Act
        (bool upkeepNeeded, ) = lottery.checkUpkeep("");

        // Assert
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepIfNotOpen() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{ value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        // Act
        (bool upkeepNeeded, ) = lottery.checkUpkeep("");

        // Assert
        assert(upkeepNeeded == false);

    }

    // Perform Upkeep

    function testUpkeepCanRunIfCheckUpkeepIsTrue() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{ value: entranceFee }();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        lottery.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        // Arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        
        // Act / Assert
        vm.expectRevert(
            abi.encodeWithSelector(
                Lottery.Lottery__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                lotteryState
            )
        );

        lottery.performUpkeep("");
    }

    modifier lotteryEnteredAnTimePassed() {
        vm.prank(PLAYER);
        lottery.enterLottery{ value: entranceFee }();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function testPerformUpkeepUpdatesLotteryAndEmitsRequestId() public lotteryEnteredAnTimePassed {
        // Act
        vm.recordLogs();
        lottery.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        Lottery.LotteryState lState = lottery.getLotteryState();
         
        assert(uint256(requestId) > 0);
        assert(uint256(lState) == 1);
    }

    // Fulfill Random Words

    modifier skipFork() {
        if(block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId) public lotteryEnteredAnTimePassed skipFork{
        // Arrange
        vm.expectRevert("nonexistent request");

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(lottery));
    }

    function testFulfillRandomWordsPicksWinnerResetsAndSendsMoney() public lotteryEnteredAnTimePassed skipFork{
        // Arrange
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;

        for(uint256 i = startingIndex; i < startingIndex + additionalEntrants; i++){
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            lottery.enterLottery{ value: entranceFee }();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        lottery.performUpkeep("");  // emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 perviousTimeStamp = lottery.getLastTimeStamp();
        
        // Pretend to be chainlink VRF to get random number and pick winner
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(lottery));

        // Assert
        assert(uint256(lottery.getLotteryState()) == 0);
        assert(lottery.getRecentWinner() != address(0));
        assert(lottery.getLengthOfPlayers() == 0);
        assert(perviousTimeStamp < lottery.getLastTimeStamp());
        assert(lottery.getRecentWinner().balance == STARTING_USER_BALANCE + prize - entranceFee);
    }
}