
local _G = _G
local string_find = string.find
local string_format = string.format
local string_gsub = string.gsub
local string_match = string.match
local tonumber = tonumber

local GameTooltip = _G.GameTooltip
local GetItemInfo = _G.GetItemInfo
local GetMouseFocus = _G.GetMouseFocus
local MerchantFrame = _G.MerchantFrame

local SELL_PRICE = _G.SELL_PRICE
local AUCTION_PRICE_PER_ITEM = _G.AUCTION_PRICE_PER_ITEM
local ITEM_UNSELLABLE = _G.ITEM_UNSELLABLE
local LE_ITEM_CLASS_RECIPE = _G.LE_ITEM_CLASS_RECIPE
local LOCKED_WITH_ITEM = _G.LOCKED_WITH_ITEM


-- Have to override GameTooltip.GetItem() after calling ClearLines().
-- Because ClearLines() leads to GetItem() not returning the name and id
-- of the previous item any more.
-- This will restore the original after the tooltip is closed.
local OriginalGetItem = GameTooltip.GetItem
GameTooltip:HookScript("OnHide", function(self)
  GameTooltip.GetItem = OriginalGetItem
end)



-- When I want to give the vendor money frame a label, this gets
-- mysteriously removed again. I could not trace down which function
-- is responsible, only that it happens between GameTooltip_ClearMoney
-- and MoneyFrame_UpdateMoney. This is why I am hooking the latter to
-- restore the label everytime.
local moneyFrameToLabel = nil

if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then

  GameTooltip:HookScript("OnHide", function(self)
    moneyFrameToLabel = nil
  end)

  hooksecurefunc("MoneyFrame_UpdateMoney", function(...)
    local moneyFrame = ...

    if moneyFrame and moneyFrameToLabel and moneyFrame == moneyFrameToLabel then
      moneyFramePrefixText = _G[moneyFrame:GetName().."PrefixText"];
      if moneyFramePrefixText:GetText() == nil then
        moneyFramePrefixText:SetText(string.format("%s:", SELL_PRICE))
        local _, moneyFrameAnchor = moneyFrame:GetPoint(1)
        moneyFrame:SetPoint("LEFT", moneyFrameAnchor:GetName(), "LEFT", 4, 0);
      end
    end
  end)
end


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

  local _, _, _, _, _, _, _, _, _, _, itemSellPrice = GetItemInfo(link)

  -- GetItemInfo() may return nil sometimes.
  -- https://wow.gamepedia.com/API_GetItemInfo
  if itemSellPrice == nil then return end


  -- Get the number of items in stack.
  -- Inspired by: https://www.wowinterface.com/downloads/info25078-BetterVendorPrice.html
  local stackCount = nil
  local focusFrame = GetMouseFocus()
  if focusFrame and focusFrame.count then
    stackCount = focusFrame.count
  -- Needed for Bagnon cached Bagnon items.
  elseif focusFrame and focusFrame:GetParent() and focusFrame:GetParent().count then
    stackCount = focusFrame:GetParent().count
  end
  -- If stackCount cannot be translated to number (particularly if it is a table in some rare cases),
  -- tonumber() returns 0.
  stackCount = tonumber(stackCount)

  -- In the TradeSkill window you cannot get stack counts like this.
  -- But mostly you have no stacks shown there... TODO (?)
  -- Also when you are hovering over the buff icon of a buff like "Rockbiter Weapon" you get a table for stackCounter.
  -- And for equipped bags you get stackCount == 0.
  if not stackCount or type(stackCount) ~= "number" or stackCount == 0 then
    stackCount = 1
  end


  -- Need this again below.
  local merchantFrameOpen = MerchantFrame and MerchantFrame:IsShown()


  -- Where should we insert our new line?
  local insertAfterLine = nil

  -- For retail-WoW we have to manually insert the unsellable label at
  -- the right position while rebuilding the tooltip,
  -- because from 10.0.2 on we cannot do the prehook any more.
  local insertUnsellable = false


  -- In classic, if there is no money frame, we not at a vendor.
  -- In Wrath and retail, if there is no money frame, we are not at a vendor AND the item is unsellable.
  if not tooltip.shownMoneyFrames then


    -- If the item has no sell price and we are not at a vendor,
    -- we add the unsellable ("No sell price") label.
    if itemSellPrice == 0 then


      if not merchantFrameOpen or not focusFrame:GetName() or not string_find(focusFrame:GetName(), "^ContainerFrame") then

        -- Before 10.0.2, we can just add the unsellable label, because due to our
        -- pre-hook we can be sure that we are the first added line.
        if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
          tooltip:AddLine(ITEM_UNSELLABLE, 1, 1, 1, false)

        -- After 10.0.2 we cannot do the pre-hook any more.
        -- But we have another way to determine the number of tooltip lines
        -- before any addon has added stuff to it:
        else

          local itemId = tonumber(string_match(link, "^.-:(%d+):"))
          local tooltipLines = C_TooltipInfo.GetItemByID(itemId).lines

          local numLines = 1
          while tooltipLines[numLines] do
            -- print(numLines .. ":", tooltipLines[numLines].args[2].stringVal)
            numLines = numLines + 1
          end
          insertAfterLine = numLines - 1
          insertUnsellable = true
        end

      end

      -- Before 10.0.2, we are done here because we already added the unsellable line.
      if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
        return
      end

    -- In classic, the items have no sell price label while not at a vendor.
    -- If this is the case, we add it. No need to check for the client version.
    else
      SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
    end
  end




  -- In classic, while you are at a vendor. The sell price is shown without the
  -- "Sell Price:" prefix label. This is not so nice, so we want to replace it
  -- with a labeled version.
  if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then
    if merchantFrameOpen then

      -- Identify the correct money frame.
      for i = 1, tooltip.shownMoneyFrames, 1 do

        local moneyFrame = _G[tooltip:GetName().."MoneyFrame"..i]
        local moneyFramePrefixText = _G[tooltip:GetName().."MoneyFrame"..i.."PrefixText"]

        if moneyFramePrefixText:GetText() == nil then

          moneyFramePrefixText:SetText(string.format("%s:", SELL_PRICE))
          local _, moneyFrameAnchor = moneyFrame:GetPoint(1)
          moneyFrame:SetPoint("LEFT", moneyFrameAnchor:GetName(), "LEFT", 4, 0);

          -- Got to remember this frame to re-add the label.
          moneyFrameToLabel = moneyFrame
          break
        end
      end
    end
  end


  if not insertAfterLine and stackCount == 1 then
    return
  end


  if not insertAfterLine and tooltip.shownMoneyFrames then

    -- Check all shown money frames of the tooltip.
    -- (There is normally only one, except other addons have added more.)
    for i = 1, tooltip.shownMoneyFrames, 1 do
      local moneyFrameName = tooltip:GetName().."MoneyFrame"..i

      -- If the money frame's PrefixText is SELL_PRICE, we assume it is the one we are looking for.

      -- In classic the vendor price is shown without "Sell Price:" while at the vendor.
      -- TODO Did I not just add this above???
      -- or _G[moneyFrameName.."PrefixText"]:GetText() == nil

      if _G[moneyFrameName.."PrefixText"]:GetText() == string_format("%s:", SELL_PRICE) then

        local _, moneyFrameAnchor = _G[moneyFrameName]:GetPoint(1)

        -- Get line number.
        insertAfterLine = tonumber(string_match(moneyFrameAnchor:GetName(), tooltip:GetName().."TextLeft(%d+)")) - 1

        -- We could take the total money value of the stack from _G[moneyFrameName].staticMoney
        -- but when Bagnon displays the items of other characters, it only shows the price of a
        -- single item even for stacks. That's why we are calculating itemSellPrice*stackCount.

        break
      end
    end
  end


  -- Something went wrong. Abort!
  if not insertAfterLine then return end



  -- Store all text and text colours of the original tooltip lines.
  -- TODO: Unfortunately I do not know how to store the "intended word wrap".
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
  for i = 2, insertAfterLine, 1 do
    AddLineOrDoubleLine(tooltip, leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i], true)
  end

  if insertUnsellable then
    tooltip:AddLine(ITEM_UNSELLABLE, 1, 1, 1, false)
  else
    SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))

    assert(stackCount > 1)
    SetTooltipMoney(tooltip, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))

    insertAfterLine = insertAfterLine + 1
  end

  for i = insertAfterLine + 1, numLines, 1 do
    AddLineOrDoubleLine(tooltip, leftText[i], rightText[i], leftTextR[i], leftTextG[i], leftTextB[i], rightTextR[i], rightTextG[i], rightTextB[i], true)
  end

end




-- In retail, we have to use this to alter the tooltip.
if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddSellPrice)

-- In classic, we use a pre-hook.
else

  local function initCode()

    -- We do a prehook to read the tooltip before any other addons
    -- have changed it.
    local OtherScripts = GameTooltip:GetScript("OnTooltipSetItem")
    local function RunOtherScripts(self, ...)
      if OtherScripts then
        return OtherScripts(self, ...)
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
      local _, productId = LibStub("LibRecipes-3.0"):GetRecipeInfo(itemId)
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


  -- I have to set my hook after all other tooltip addons.
  -- Because I am doing a ClearLines(), which may cause other addons (like BagSync)
  -- to clear the attribute they are using to only execute on the first of the
  -- two calls of OnTooltipSetItem().
  -- Therefore take this timer!
  local startupFrame = CreateFrame("Frame")
  startupFrame:RegisterEvent("PLAYER_LOGIN")
  startupFrame:SetScript("OnEvent", function(self, event, ...)
    C_Timer.After(3.0, initCode)
  end)

end

