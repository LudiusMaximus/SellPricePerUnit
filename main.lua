local folderName = ...
local L = LibStub("AceAddon-3.0"):NewAddon(folderName, "AceTimer-3.0")


local _G = _G
local string_find = string.find
local string_format = string.format
local string_gsub = string.gsub
local string_match = string.match
local tonumber = tonumber

local GameTooltip = _G.GameTooltip
local GetItemInfo = _G.GetItemInfo
local GetMouseFocus = _G.GetMouseFocus

local SELL_PRICE = _G.SELL_PRICE
local AUCTION_PRICE_PER_ITEM = _G.AUCTION_PRICE_PER_ITEM



-- I have to set my hook after all other tooltip addons.
-- Because I am doing a ClearLines(), which may cause other addons (like BagSync)
-- to clear the attribute they are using to only execute on the first of the
-- two calls of OnTooltipSetItem().
-- Therefore take this timer!
local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_LOGIN")
startupFrame:SetScript("OnEvent", function(self, event, ...)
  L:ScheduleTimer("initCode", 3.0)
end)



-- Have to override GameTooltip.GetItem() after calling ClearLines().
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





local function AddSellPrice(tooltip)

  local name, link = tooltip:GetItem()

  -- Just to be on the safe side...
  if not name or not link then return end

  local _, _, _, _, _, _, _, itemStackCount, _, _, itemSellPrice = GetItemInfo(link)


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
  -- In the TradeSkill window you cannot get stack counts like this.
  -- But mostly you have no stacks shown there... TODO (?)
  if not stackCount then
    stackCount = 1
  end
  
  
  local merchantFrameOpen = MerchantFrame and MerchantFrame:IsShown()


  -- If the item has no sell price, we can stop here.
  -- If necessary, we add the "No sell price" label.
  if itemSellPrice == 0 then
    if not merchantFrameOpen or not focusFrame:GetName() or not string_find(focusFrame:GetName(), "^ContainerFrame") then
      tooltip:AddLine(ITEM_UNSELLABLE, 1, 1, 1, false)
    end
    return
  end


   -- If there is no money frame yet, put it there!
  if not tooltip.shownMoneyFrames then 
    SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
  end




  -- Now about that sell price per unit!

  -- The money frame is anchored to a blank line of the tootlip.
  -- Find out which line it is.
  local moneyFrameLineNumber = nil


  -- Check all shown money frames of the tooltip.
  -- (There is normally only one, except other addons have added more.)
  for i = 1, tooltip.shownMoneyFrames, 1 do

    local moneyFrameName = tooltip:GetName().."MoneyFrame"..i

    -- If the money frame's PrefixText is SELL_PRICE, we assume it is the one we are looking for.
    -- In classic the vendor price is shown without "Sell Price:" while at the vendor.
    if _G[moneyFrameName.."PrefixText"]:GetText() == nil or _G[moneyFrameName.."PrefixText"]:GetText() == string_format("%s:", SELL_PRICE) then
    
      local _, moneyFrameAnchor = _G[moneyFrameName]:GetPoint(1)

      -- Get line number.
      moneyFrameLineNumber = tonumber(string_match(moneyFrameAnchor:GetName(), tooltip:GetName().."TextLeft(%d+)"))

      -- We could take the total money value of the stack from _G[moneyFrameName].staticMoney
      -- but when Bagnon displays the items of other characters, it only shows the price of a
      -- single item even for stacks. That's why we are calculating itemSellPrice*stackCount.

      break
    end

  end

  if not moneyFrameLineNumber then
    return  
  end


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
  local numLines = tooltip:NumLines()

  -- Store all lines of the original tooltip.
  for i = 1, numLines, 1 do
    leftText[i] = _G[tooltip:GetName().."TextLeft"..i]:GetText()
    leftTextR[i], leftTextG[i], leftTextB[i] = _G[tooltip:GetName().."TextLeft"..i]:GetTextColor()

    rightText[i] = _G[tooltip:GetName().."TextRight"..i]:GetText()
    rightTextR[i], rightTextG[i], rightTextB[i] = _G[tooltip:GetName().."TextRight"..i]:GetTextColor()
  end


  tooltip:ClearLines()
  -- Got to override GameTooltip.GetItem(), such that other addons can still use it
  -- to learn which item is displayed. Will be restored after GameTooltip:OnHide() (see above).
  tooltip.GetItem = function() return name, link end


  -- Never word wrap the title line!
  AddLineOrDoubleLine(tooltip, leftText[1], rightText[1], leftTextR[1], leftTextG[1], leftTextB[1], rightTextR[1], rightTextG[1], rightTextB[1], false)

  -- Refill the tooltip with the stored lines plus the new "per unit" money frame.
  for i = 2, moneyFrameLineNumber-1, 1 do
    AddLineOrDoubleLine(tooltip, leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i], true)
  end
  
  SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
  if stackCount > 1 then
    SetTooltipMoney(tooltip, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
  end

  for i = moneyFrameLineNumber+1, numLines, 1 do
    AddLineOrDoubleLine(tooltip, leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i], true)
  end

end



function L:initCode()

  -- We do a prehook to read the tooltip before any other addons
  -- have changed it.
  local otherScripts = GameTooltip:GetScript("OnTooltipSetItem")
  local function RunOtherScripts(self, ...)
    if otherScripts then
      return otherScripts(self, ...)
    else
      return
    end
  end


  GameTooltip:SetScript("OnTooltipSetItem", function(self, ...)

    local name, link = self:GetItem()
    if not name or not link then return RunOtherScripts(self, ...) end

    local _, _, _, _, _, _, _, _, _, _, _, itemTypeId, itemSubTypeId = GetItemInfo(link)
    
    -- Non recipe items are no problem, because only one call of OnTooltipSetItem()
    if itemTypeId ~= LE_ITEM_CLASS_RECIPE or itemSubTypeId == LE_ITEM_RECIPE_BOOK then
      AddSellPrice(self)
      return RunOtherScripts(self, ...)
    end
    
    
    -- If the recipe has no product, there is also only one call of OnTooltipSetItem().
    local itemId = tonumber(string_match(link, "^.-:(%d+):"))
    local _, productId = LibStub("LibRecipes-2.0"):GetRecipeInfo(itemId)
    if not productId then
      AddSellPrice(self)
      return RunOtherScripts(self, ...)
    end
      

    -- Otherwise, find out if this is the first or second call of OnTooltipSetItem().
    -- We recognise this by checking if the last line starts with "Requires"
    -- preceeded by an empty line.
    -- (While at a vendor the moneyFrame is the last line, so we have to check the second last.)
    local secondLastLine = _G[self:GetName().."TextLeft"..(self:NumLines()-1)]:GetText()
    local lastLine = _G[self:GetName().."TextLeft"..self:NumLines()]:GetText()
    local searchPattern = string_gsub(LOCKED_WITH_ITEM, "%%s", ".-")
    if not string_find(lastLine, "^\n.-"..searchPattern) and not string_find(secondLastLine, "^\n.-"..searchPattern) then
      
      -- For debugging:
      -- print("|n|nPREHOOK: This is the first call, STOP!")
      -- for i = 1, self:NumLines(), 1 do
        -- local line = _G[self:GetName().."TextLeft"..i]:GetText()
        -- print (i, line)
      -- end
      
      return
      
    else
    
      -- print("|n|nPREHOOK: This is the second call!")
      -- for i = 1, self:NumLines(), 1 do
        -- local line = _G[self:GetName().."TextLeft"..i]:GetText()
        -- print (i, line)
      -- end
    
      AddSellPrice(self)
      return RunOtherScripts(self, ...)
    
    end

  end)

end
