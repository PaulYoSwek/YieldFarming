pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import "@studydefi/money-legos/dydx/contracts/DydxFlashloanBase.sol";
import "@studydefi/money-legos/dydx/contracts/ICallee.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './Compound.sol';

contract YieldFarmer is ICallee, DydxFlashloanBase, Compound {
  enum Direction { Deposit, Withdraw } 
  struct Operation {
    address token;
    address cToken;
    Direction direction;
    uint amountProvided;
    uint amountBorrowed;
  }
  address public owner;


  constructor(address _comptroller) Compound(_comptroller) public {
    owner = msg.sender;
  }

// Lend money, invest money 
  function openPosition(
    address _solo, 
    address _token, 
    address _cToken,
    uint _amountProvided, 
    uint _amountBorrowed
  ) external {
    require(msg.sender == owner, 'only owner');
    IERC20(_token).transferFrom(msg.sender, address(this), _amountProvided);
    //2 wei is used to pay for flashloan
    _initiateFlashloan(_solo, _token, _cToken, Direction.Deposit, _amountProvided - 2, _amountBorrowed);
  }

// Repay the invested money and receive invested money and the extra money made from investing (hopefully) 
  function closePosition(
    address _solo, 
    address _token, 
    address _cToken
  ) external {
    require(msg.sender == owner, 'only owner');
    //2 wei is used to pay for flashloan
    IERC20(_token).transferFrom(msg.sender, address(this), 2);
    claimComp();
    uint borrowBalance = getBorrowBalance(_cToken);

    // Function only works if the money you invested is high enough to pay back the borrowed money + interest

    // Pay your debs + interest (you lend this money as well from a flashloan)
    _initiateFlashloan(_solo, _token, _cToken, Direction.Withdraw, 0, borrowBalance);

    // Your actually earnings for providing liquidity
    address compAddress = getCompAddress();
    IERC20 comp = IERC20(compAddress);
    uint compBalance = comp.balanceOf(address(this));
    comp.transfer(msg.sender, compBalance);

    // Receive the money you made for lending out your money, will be send back to the flashloan you just used to get this money
    IERC20 token = IERC20(_token);
    uint tokenBalance = token.balanceOf(address(this));
    token.transfer(msg.sender, tokenBalance);
  }

  // Defined by the studydefi library
  function callFunction(
    address sender,
    Account.Info memory account,
    bytes memory data
  ) public {
    Operation memory operation = abi.decode(data, (Operation));

    if(operation.direction == Direction.Deposit) {
      // Lend out the received money from the flashloan, this is the investing part, you hope this money will increase while its there
      supply(operation.cToken, operation.amountProvided + operation.amountBorrowed);
      enterMarket(operation.cToken);
      // Borrow the same amount invested, to pay back the flashloan you lend the money from to invest in the first place 
      // (you are now in double the debt, byt you hope your investment makes you money, to repay this back later) 
      borrow(operation.cToken, operation.amountBorrowed);
    } else {
      // Repay the borrowed amount (the same amount your intial investing was, the money you lend from the initial flashloan)
      repayBorrow(operation.cToken, operation.amountBorrowed);
      uint cTokenBalance = getcTokenBalance(operation.cToken);
      // Get all the money invested + hopefully some provit from investing
      redeem(operation.cToken, cTokenBalance);
    }
  }

  function _initiateFlashloan(
    address _solo, 
    address _token, 
    address _cToken, 
    Direction _direction,
    uint _amountProvided, 
    uint _amountBorrowed
  )
    internal
  {
    ISoloMargin solo = ISoloMargin(_solo);

    // Get marketId from token address
    uint256 marketId = _getMarketIdFromTokenAddress(_solo, _token);

    // Calculate repay amount (_amount + (2 wei))
    // Approve transfer from
    uint256 repayAmount = _getRepaymentAmountInternal(_amountBorrowed);
    IERC20(_token).approve(_solo, repayAmount);

    // 1. Withdraw $
    // 2. Call callFunction(...)
    // 3. Deposit back $
    Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

    operations[0] = _getWithdrawAction(marketId, _amountBorrowed);
    operations[1] = _getCallAction(
        // Encode MyCustomData for callFunction
        abi.encode(Operation({
          token: _token, 
          cToken: _cToken, 
          direction: _direction,
          amountProvided: _amountProvided, 
          amountBorrowed: _amountBorrowed
        }))
    );
    operations[2] = _getDepositAction(marketId, repayAmount);

    Account.Info[] memory accountInfos = new Account.Info[](1);
    accountInfos[0] = _getAccountInfo();

    solo.operate(accountInfos, operations);
  }
}