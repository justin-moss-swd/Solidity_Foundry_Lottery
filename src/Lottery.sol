//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

/**
 * @title Lottery Contract
 * @author Justin Moss 2023
 * @notice Contract for creating a Raffle-based Lottery
 * @dev Impements Chainlink VRFv2
 */
contract Lottery is VRFConsumerBaseV2 {
    error Lottery__NotEnoughEthSent();
    error Lottery__TransferFailed();
    error Lottery__LotteryNotOpen();
    error Lottery__UpkeepNotNeeded(
        uint256 currentBalance,
        uint256 numPlayers,
        uint256 lotteryState
    );

    /* Type Declarations */
    enum LotteryState {
        OPEN,
        CALCULATING
    }

    /* State variable */
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval;
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    
    uint256 private s_lastTimeStamp;
    address payable[] private s_players;
    address private s_recentWinner;
    LotteryState private s_lotteryState;

    /* Events */

    event EnteredLottery(address indexed player);
    event PickedWinner(address indexed winner);
    event RequestLotteryWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee, 
        uint256 interval, 
        address vrfCoordinator, 
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator);
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
    }

    function enterLottery() external payable {        
        if(msg.value < i_entranceFee) {
            revert Lottery__NotEnoughEthSent();
        }

        if(s_lotteryState != LotteryState.OPEN){
            revert Lottery__LotteryNotOpen();
        }

        s_players.push(payable(msg.sender));
        emit EnteredLottery(msg.sender);
    }

    /**
      * @dev Chainlink Automated node call to check for upkeep
      * The following should be true:
      * 1. The time interval has passed between lottery runs
      * 2. The lottery is in the OPEN state
      * 3. The contract has ETH
      * 4. (Implicit) The subscriptions is funded with LINK
      */
    function checkUpkeep(
        bytes memory /*checkData*/
    ) public view returns (bool upkeepNeeded, bytes memory /*performData*/) {
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >= i_interval);
        bool isOpen = LotteryState.OPEN == s_lotteryState;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = (timeHasPassed && isOpen && hasBalance && hasPlayers);

        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /*performData*/) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if(!upkeepNeeded){
            revert Lottery__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_lotteryState)
            );
        }

        s_lotteryState = LotteryState.CALCULATING;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,  // Gas lane
            i_subscriptionId,  // ID funded with LINK
            REQUEST_CONFIRMATIONS,  // Number of block confirmations
            i_callbackGasLimit,  // Gas limit to get random number
            NUM_WORDS  // Number of random numbers
        );

        emit RequestLotteryWinner(requestId);
    }

    // CEI: Checks, Effects, Interactions
    function fulfillRandomWords(
        uint256 /*requestId*/,
        uint256[] memory randomWords
    ) internal override {
        // Checks
        // Effects
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable winner = s_players[indexOfWinner];
        s_recentWinner = winner;
        s_lotteryState = LotteryState.OPEN;
        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;

        emit PickedWinner(winner);

        // Interactions (Other contracts)
        (bool success,) = winner.call{value: address(this).balance}("");
        if(!success) {
             revert Lottery__TransferFailed();
        }       
    }

    /* Getter Functions */

    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getLotteryState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[indexOfPlayer];
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    function getLengthOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }
}