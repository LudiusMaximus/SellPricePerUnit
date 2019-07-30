

local _G = _G
local string_format = string.format
local string_match = string.match
local tonumber = tonumber

local GameTooltip = _G.GameTooltip
local GetItemInfo = _G.GetItemInfo
local GetMouseFocus = _G.GetMouseFocus

local LE_ITEM_CLASS_RECIPE = _G.LE_ITEM_CLASS_RECIPE
local SELL_PRICE = _G.SELL_PRICE
local AUCTION_PRICE_PER_ITEM = _G.AUCTION_PRICE_PER_ITEM



-- Have to override GameTooltip.GetItem() after calling ClearLines().
-- This will restore the original after the tooltip is closed.
local originalGetItem = GameTooltip.GetItem
GameTooltip:HookScript("OnHide", function(self)
  GameTooltip.GetItem = originalGetItem
end)



-- TODO: This is not working for recipes that do not produce an item...
local skipNextRecipeCall = true




GameTooltip:HookScript("OnTooltipSetItem", function(self)

  if not self.shownMoneyFrames then return end

  local name, link = self:GetItem()
    
  local _, _, _, _, _, _, _, itemStackCount, _, _, itemSellPrice, itemTypeId = GetItemInfo(link)
  
  
  if itemStackCount == nil or itemStackCount == 1 or itemSellPrice == 0 then return end
  
  
  -- TODO: This is not working for recipes that do not produce an item...
  if (itemTypeId == LE_ITEM_CLASS_RECIPE) then
    if skipNextRecipeCall then
      skipNextRecipeCall = false
      return
    else
      skipNextRecipeCall = true
    end
  end
  
  -- Get the number of items in stack.
  -- Inspired by: https://www.wowinterface.com/downloads/info25078-BetterVendorPrice.html
  local focusFrame = GetMouseFocus()
  if not focusFrame then return end
  
  local count = tonumber(focusFrame.count) or 1
  if count <= 1 then return end


  -- The money frame is anchored to a blank line of the tootlip.
  -- Find out which line it is and how much money is displayed.
  local moneyFrameLineNumber = nil
  local money = nil
  
  -- Check all shown money frames of the tooltip.
  -- (There is normally only one, except other addons have added more.)
  for i = 1, self.shownMoneyFrames, 1 do

    local moneyFrameName = self:GetName().."MoneyFrame"..i

    -- If the money frame's PrefixText is "SELL_PRICE:", we assume it is the one we are looking for.
    if _G[moneyFrameName.."PrefixText"]:GetText() == string_format("%s:", SELL_PRICE) then
      local _, moneyFrameAnchor = _G[moneyFrameName]:GetPoint(1)
      
      -- Get line number and amount of money.
      moneyFrameLineNumber = tonumber(string_match(moneyFrameAnchor:GetName(), self:GetName().."TextLeft(%d+)"))
      money = _G[moneyFrameName].staticMoney

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
  
  -- Refill the tooltip with the stored lines plus the new "per unit" money frame.
  for i = 1, moneyFrameLineNumber-1, 1 do
  
    if rightText[i] then
      self:AddDoubleLine(leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i])
    else
      -- TODO: Unfortunately I do not know how to store the "indented word wrap".
      --       Therefore, we have to put wrap=true for all lines in the new tooltip.
      self:AddLine(leftText[i], leftTextR[i], leftTextG[i], leftTextB[i], true)
    end
  
  end
  
  SetTooltipMoney(self, money, nil, string_format("%s:", SELL_PRICE))
  SetTooltipMoney(self, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
  
  for i = moneyFrameLineNumber+1, numLines, 1 do
  
    if rightText[i] then
      self:AddDoubleLine(leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i])
    else
      -- TODO: Unfortunately I do not know how to store the "indented word wrap".
      --       Therefore, we have to put wrap=true for all lines in the new tooltip.
      self:AddLine(leftText[i], leftTextR[i], leftTextG[i], leftTextB[i], true)
    end
  
  end
  
end
)


