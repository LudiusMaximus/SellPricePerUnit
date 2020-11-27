

local _G = _G
local string_format = string.format
local string_match = string.match
local tonumber = tonumber

local GameTooltip = _G.GameTooltip
local GetItemInfo = _G.GetItemInfo
local GetMouseFocus = _G.GetMouseFocus

local SELL_PRICE = _G.SELL_PRICE
local AUCTION_PRICE_PER_ITEM = _G.AUCTION_PRICE_PER_ITEM



-- Have to override GameTooltip.GetItem() after calling ClearLines().
-- Because ClearLines() leads to GetItem() not returning the name and id
-- of the previous item any more.
-- This will restore the original after the tooltip is closed.
local originalGetItem = GameTooltip.GetItem
GameTooltip:HookScript("OnHide", function(self)
  GameTooltip.GetItem = originalGetItem
end)



local function AddLineOrDoubleLine(tooltip, leftText, rightText, leftTextR, leftTextG, leftTextB, rightTextR, rightTextG, rightTextB, intendedWordWrap)
  if rightText then
    tooltip:AddDoubleLine(leftText, rightText, leftTextR, leftTextG, leftTextB, rightTextR, rightTextG, rightTextB)
  else
    tooltip:AddLine(leftText, leftTextR, leftTextG, leftTextB, intendedWordWrap)
  end
end





GameTooltip:HookScript("OnTooltipSetItem", function(self)

  if not self.shownMoneyFrames then return end

  local name, link = self:GetItem()

  -- Just to be on the safe side...
  if not name or not link then return end

  local _, _, _, _, _, _, _, itemStackCount, _, _, itemSellPrice = GetItemInfo(link)

  if itemStackCount == nil or itemStackCount == 1 or itemSellPrice == 0 then return end


  -- Get the number of items in stack.
  -- Inspired by: https://www.wowinterface.com/downloads/info25078-BetterVendorPrice.html
  local stackCount = nil
  local focusFrame = GetMouseFocus()
  if focusFrame and focusFrame.count then
    stackCount = focusFrame.count
  -- Needed for Bagnon cached Bagnon items.
  elseif focusFrame:GetParent() and focusFrame:GetParent().count then
    stackCount = focusFrame:GetParent().count
  end
  stackCount = tonumber(stackCount)
  if not stackCount or stackCount <= 1 then return end


  -- The money frame is anchored to a blank line of the tootlip.
  -- Find out which line it is.
  local moneyFrameLineNumber = nil

  -- Check all shown money frames of the tooltip.
  -- (There is normally only one, except other addons have added more.)
  for i = 1, self.shownMoneyFrames, 1 do

    local moneyFrameName = self:GetName().."MoneyFrame"..i

    -- If the money frame's PrefixText is "SELL_PRICE:", we assume it is the one we are looking for.
    if _G[moneyFrameName.."PrefixText"]:GetText() == string_format("%s:", SELL_PRICE) then
      local _, moneyFrameAnchor = _G[moneyFrameName]:GetPoint(1)

      -- Get line number.
      moneyFrameLineNumber = tonumber(string_match(moneyFrameAnchor:GetName(), self:GetName().."TextLeft(%d+)"))

      -- We could take the total money value of the stack from _G[moneyFrameName].staticMoney
      -- but when Bagnon displays the items of other characters, it only shows the price of a
      -- single item even for stacks. That's why we are calculating itemSellPrice*stackCount.

      break
    end

  end


  if not moneyFrameLineNumber then return end


  -- Store all text and text colours of the original tooltip lines.
  -- TODO: Unfortunately I do not know how to store the "indented word wrap".
  --       Therefore, we have to put wrap=true for all lines in the new tooltip.
  local leftText = {}
  local leftTextR = {}
  local leftTextG = {}
  local leftTextB = {}

  local rightText = {}
  local rightTextR = {}
  local rightTextG = {}
  local rightTextB = {}

  -- Store the number of lines for after ClearLines().
  local numLines = self:NumLines()

  -- Store all lines of the original tooltip.
  for i = 1, numLines, 1 do
    leftText[i] = _G[self:GetName().."TextLeft"..i]:GetText()
    leftTextR[i], leftTextG[i], leftTextB[i] = _G[self:GetName().."TextLeft"..i]:GetTextColor()

    rightText[i] = _G[self:GetName().."TextRight"..i]:GetText()
    rightTextR[i], rightTextG[i], rightTextB[i] = _G[self:GetName().."TextRight"..i]:GetTextColor()
  end


  self:ClearLines()
  -- Got to override GameTooltip.GetItem(), such that other addons can still use it
  -- to learn which item is displayed. Will be restored after GameTooltip:OnHide() (see above).
  self.GetItem = function(self) return name, link end


  -- Never word wrap the title line!
  AddLineOrDoubleLine(self, leftText[1], rightText[1], leftTextR[1], leftTextG[1], leftTextB[1], rightTextR[1], rightTextG[1], rightTextB[1], false)

  -- Refill the tooltip with the stored lines plus the new "per unit" money frame.
  for i = 2, moneyFrameLineNumber-1, 1 do
    AddLineOrDoubleLine(self, leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i], true)
  end

  SetTooltipMoney(self, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
  SetTooltipMoney(self, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))

  for i = moneyFrameLineNumber+1, numLines, 1 do
    AddLineOrDoubleLine(self, leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i], true)
  end

end
)


