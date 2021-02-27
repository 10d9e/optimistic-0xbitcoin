// SPDX-License-Identifier: MIT
pragma solidity >0.6.0 <0.8.0;
// ----------------------------------------------------------------------------
// '0xBitcoin Token' contract
// Mineable ERC20 Token using Proof Of Work
//
// Symbol      : 0xBTC
// Name        : 0xBitcoin Token
// Total supply: 21,000,000.0
// Decimals    : 8
//
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// Safe maths
// ----------------------------------------------------------------------------
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        require(c >= a);
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require(b <= a);
        c = a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a * b;
        require(a == 0 || c / a == b);
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require(b > 0);
        c = a / b;
    }
}

library ExtendedMath {
    //return the smaller of the two inputs (a or b)
    function limitLessThan(uint256 a, uint256 b)
        internal
        pure
        returns (uint256 c)
    {
        if (a > b) return b;
        return a;
    }
}

// ----------------------------------------------------------------------------
// ERC Token Standard #20 Interface
// https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
// ----------------------------------------------------------------------------
interface ERC20Interface {
    function totalSupply() external returns (uint256);
    function balanceOf(address tokenOwner)
        external
        returns (uint256 balance);
    function allowance(address tokenOwner, address spender)
        external
        returns (uint256 remaining);
    function transfer(address to, uint256 tokens) external returns (bool success);
    function approve(address spender, uint256 tokens)
        external
        returns (bool success);
    function transferFrom(
        address from,
        address to,
        uint256 tokens
    ) external returns (bool success);
    event Transfer(address indexed from, address indexed to, uint256 tokens);
    event Approval(
        address indexed tokenOwner,
        address indexed spender,
        uint256 tokens
    );
}

// ----------------------------------------------------------------------------
// Contract function to receive approval and execute function in one call
//
// Borrowed from MiniMeToken
// ----------------------------------------------------------------------------
interface ApproveAndCallFallBack {
    function receiveApproval(
        address from,
        uint256 tokens,
        address token,
        bytes memory data
    ) external;
}

// ----------------------------------------------------------------------------
// ERC20 Token, with the addition of symbol, name and decimals and an
// initial fixed supply
// ----------------------------------------------------------------------------
contract _0xBitcoinToken is ERC20Interface {
    using SafeMath for uint256;
    using ExtendedMath for uint256;
    string public symbol;
    string public name;
    uint8 public decimals;
    uint256 public _totalSupply;
    uint256 public latestDifficultyPeriodStarted;
    uint256 public epochCount; //number of 'blocks' mined
    uint256 public _BLOCKS_PER_READJUSTMENT = 1024;
    //a little number
    uint256 public _MINIMUM_TARGET = 2**16;
    //a big number is easier ; just find a solution that is smaller
    uint256 public _MAXIMUM_TARGET = 2**234;
    uint256 public miningTarget;
    bytes32 public challengeNumber; //generate a new one when a new reward is minted
    uint256 public rewardEra;
    uint256 public maxSupplyForEra;
    address public lastRewardTo;
    uint256 public lastRewardAmount;
    uint256 public lastRewardEthBlockNumber;
    bool locked = false;
    mapping(bytes32 => bytes32) solutionForChallenge;
    uint256 public tokensMinted;
    mapping(address => uint256) balances;
    mapping(address => mapping(address => uint256)) allowed;
    event Mint(
        address indexed from,
        uint256 reward_amount,
        uint256 epochCount,
        bytes32 newChallengeNumber
    );
    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    constructor() {
        symbol = "0xBTC";
        name = "0xBitcoin Token";
        decimals = 8;
        _totalSupply = 21000000 * 10**uint256(decimals);
        if (locked) revert();
        locked = true;
        tokensMinted = 0;
        rewardEra = 0;
        maxSupplyForEra = _totalSupply.div(2);
        miningTarget = _MAXIMUM_TARGET;
        latestDifficultyPeriodStarted = block.number;
        _startNewMiningEpoch();
        //The owner gets nothing! You must mine this ERC20 token
    }
    function mint(uint256 nonce, bytes32 challenge_digest)
        public
        returns (bool success)
    {
        //the PoW must contain work that includes a recent ethereum block hash (challenge number) and the msg.sender's address to prevent MITM attacks
        bytes32 digest = keccak256(abi.encodePacked(challengeNumber, msg.sender, nonce));
        //the challenge digest must match the expected
        if (digest != challenge_digest) revert();
        //the digest must be smaller than the target
        if (uint256(digest) > miningTarget) revert();
        //only allow one reward for each challenge
        bytes32 solution = solutionForChallenge[challengeNumber];
        solutionForChallenge[challengeNumber] = digest;
        if (solution != 0x0) revert(); //prevent the same answer from awarding twice
        uint256 reward_amount = getMiningReward();
        balances[msg.sender] = balances[msg.sender].add(reward_amount);
        tokensMinted = tokensMinted.add(reward_amount);
        //Cannot mint more tokens than there are
        assert(tokensMinted <= maxSupplyForEra);
        //set readonly diagnostics data
        lastRewardTo = msg.sender;
        lastRewardAmount = reward_amount;
        lastRewardEthBlockNumber = block.number;
        _startNewMiningEpoch();
        emit Mint(msg.sender, reward_amount, epochCount, challengeNumber);
        return true;
    }
    //a new 'block' to be mined
    function _startNewMiningEpoch() internal {
        // if max supply for the era will be exceeded next reward round then enter the new era before that happens
        // 40 is the final reward era, almost all tokens minted
        // once the final era is reached, more tokens will not be given out because the assert function
        if (
            tokensMinted.add(getMiningReward()) > maxSupplyForEra &&
            rewardEra < 39
        ) {
            rewardEra = rewardEra + 1;
        }
        // set the next minted supply at which the era will change
        // total supply is 2100000000000000  because of 8 decimal places
        maxSupplyForEra = _totalSupply - _totalSupply.div(2**(rewardEra + 1));
        epochCount = epochCount.add(1);
        //every so often, readjust difficulty. Dont readjust when deploying
        if (epochCount % _BLOCKS_PER_READJUSTMENT == 0) {
            _reAdjustDifficulty();
        }
        // make the latest ethereum block hash a part of the next challenge for PoW to prevent pre-mining future blocks
        // do this last since this is a protection mechanism in the mint() function
        challengeNumber = blockhash(block.number - 1);
    }
    // https://en.bitcoin.it/wiki/Difficulty#What_is_the_formula_for_difficulty.3F
    // as of 2017 the bitcoin difficulty was up to 17 zeroes, it was only 8 in the early days
    // readjust the target by 5 percent
    function _reAdjustDifficulty() internal {
        uint256 ethBlocksSinceLastDifficultyPeriod =
            block.number - latestDifficultyPeriodStarted;
        // assume 360 ethereum blocks per hour
        // we want miners to spend 10 minutes to mine each 'block', about 60 ethereum blocks = one 0xbitcoin epoch
        uint256 epochsMined = _BLOCKS_PER_READJUSTMENT; //256
        uint256 targetEthBlocksPerDiffPeriod = epochsMined * 60; //should be 60 times slower than ethereum
        //if there were less eth blocks passed in time than expected
        if (ethBlocksSinceLastDifficultyPeriod < targetEthBlocksPerDiffPeriod) {
            uint256 excess_block_pct =
                (targetEthBlocksPerDiffPeriod.mul(100)).div(
                    ethBlocksSinceLastDifficultyPeriod
                );
            uint256 excess_block_pct_extra =
                excess_block_pct.sub(100).limitLessThan(1000);
            // If there were 5% more blocks mined than expected then this is 5.  If there were 100% more blocks mined than expected then this is 100.
            // make it harder
            miningTarget = miningTarget.sub(
                miningTarget.div(2000).mul(excess_block_pct_extra)
            ); //by up to 50 %
        } else {
            uint256 shortage_block_pct =
                (ethBlocksSinceLastDifficultyPeriod.mul(100)).div(
                    targetEthBlocksPerDiffPeriod
                );
            uint256 shortage_block_pct_extra =
                shortage_block_pct.sub(100).limitLessThan(1000); //always between 0 and 1000
            // make it easier
            miningTarget = miningTarget.add(
                miningTarget.div(2000).mul(shortage_block_pct_extra)
            ); //by up to 50 %
        }
        latestDifficultyPeriodStarted = block.number;
        if (miningTarget < _MINIMUM_TARGET) //very difficult
        {
            miningTarget = _MINIMUM_TARGET;
        }
        if (miningTarget > _MAXIMUM_TARGET) //very easy
        {
            miningTarget = _MAXIMUM_TARGET;
        }
    }
    // this is a recent ethereum block hash, used to prevent pre-mining future blocks
    function getChallengeNumber() public view returns (bytes32) {
        return challengeNumber;
    }
    // the number of zeroes the digest of the PoW solution requires.  Auto adjusts
    function getMiningDifficulty() public view returns (uint256) {
        return _MAXIMUM_TARGET.div(miningTarget);
    }
    function getMiningTarget() public view returns (uint256) {
        return miningTarget;
    }
    // 21m coins total
    // reward begins at 50 and is cut in half every reward era (as tokens are mined)
    function getMiningReward() public view returns (uint256) {
        //once we get half way thru the coins, only get 25 per block
        //every reward era, the reward amount halves.
        return (50 * 10**uint256(decimals)).div(2**rewardEra);
    }
    
    // ------------------------------------------------------------------------
    // Total supply
    // ------------------------------------------------------------------------
    function totalSupply() public override view returns (uint256) {
        return _totalSupply - balances[address(0)];
    }
    // ------------------------------------------------------------------------
    // Get the token balance for account `tokenOwner`
    // ------------------------------------------------------------------------
    function balanceOf(address tokenOwner)
        public
        override
        view
        returns (uint256 balance)
    {
        return balances[tokenOwner];
    }
    // ------------------------------------------------------------------------
    // Transfer the balance from token owner's account to `to` account
    // - Owner's account must have sufficient balance to transfer
    // - 0 value transfers are allowed
    // ------------------------------------------------------------------------
    function transfer(address to, uint256 tokens)
        public override
        returns (bool success)
    {
        balances[msg.sender] = balances[msg.sender].sub(tokens);
        balances[to] = balances[to].add(tokens);
        Transfer(msg.sender, to, tokens);
        return true;
    }
    // ------------------------------------------------------------------------
    // Token owner can approve for `spender` to transferFrom(...) `tokens`
    // from the token owner's account
    //
    // https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
    // recommends that there are no checks for the approval double-spend attack
    // as this should be implemented in user interfaces
    // ------------------------------------------------------------------------
    function approve(address spender, uint256 tokens)
        public
        override
        returns (bool success)
    {
        allowed[msg.sender][spender] = tokens;
        Approval(msg.sender, spender, tokens);
        return true;
    }
    // ------------------------------------------------------------------------
    // Transfer `tokens` from the `from` account to the `to` account
    //
    // The calling account must already have sufficient tokens approve(...)-d
    // for spending from the `from` account and
    // - From account must have sufficient balance to transfer
    // - Spender must have sufficient allowance to transfer
    // - 0 value transfers are allowed
    // ------------------------------------------------------------------------
    function transferFrom(
        address from,
        address to,
        uint256 tokens
    ) public override returns (bool success) {
        balances[from] = balances[from].sub(tokens);
        allowed[from][msg.sender] = allowed[from][msg.sender].sub(tokens);
        balances[to] = balances[to].add(tokens);
        Transfer(from, to, tokens);
        return true;
    }
    // ------------------------------------------------------------------------
    // Returns the amount of tokens approved by the owner that can be
    // transferred to the spender's account
    // ------------------------------------------------------------------------
    function allowance(address tokenOwner, address spender)
        public
        override
        view
        returns (uint256 remaining)
    {
        return allowed[tokenOwner][spender];
    }
    // ------------------------------------------------------------------------
    // Token owner can approve for `spender` to transferFrom(...) `tokens`
    // from the token owner's account. The `spender` contract function
    // `receiveApproval(...)` is then executed
    // ------------------------------------------------------------------------
    function approveAndCall(
        address spender,
        uint256 tokens,
        bytes memory data
    ) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
        Approval(msg.sender, spender, tokens);
        ApproveAndCallFallBack(spender).receiveApproval(
            msg.sender,
            tokens,
            address(this),
            data
        );
        return true;
    }
    // ------------------------------------------------------------------------
    // Don't accept ETH
    // ------------------------------------------------------------------------
    fallback() external payable {
        revert();
    }
    receive() external payable {
        revert();
    }
}
