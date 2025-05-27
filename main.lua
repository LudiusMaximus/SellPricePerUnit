
local _G = _G
local string_find = string.find
local string_format = string.format
local string_gsub = string.gsub
local string_match = string.match
local tonumber = tonumber

local GameTooltip = _G.GameTooltip
local GetItemInfo = _G.C_Item.GetItemInfo
local GetMouseFoci = _G.GetMouseFoci
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



-- Normally, we want the money frame or unsellable label to appear in the tooltip
-- at the bottom of the all other WoW stock tooltip lines; i.e. before any other addon
-- has added further lines to the tooltip.
-- Before 10.0.2 this was able with a pre-hook.
-- After 10.0.2, we try to determine the tooltip line after which to insert
-- by the number of lines returned by C_TooltipInfo.GetItemByID(itemId).
-- This works OK for bag items (except that class restriction lines may be ommitted in the actual tooltip).
-- For items sold in a merchant frame, it not good enough! Because the actual tooltip can have so many
-- more lines added to the stock tooltip, which are not returned by C_TooltipInfo.GetItemByID(itemId)
-- (e.g. Renown required, Season, Upgrade Level, "Shift click to by a different amount").
-- Taking care of all these special cases would be too much of a pain for the little gain.
local function GetLastTooltipLine(itemId)

  -- Get default tooltip lines for this item.
  local tooltipLines = C_TooltipInfo.GetItemByID(itemId).lines

  -- Determine the last line.
  local lastLine = 1
  local ingnoredLines = 0
  while tooltipLines[lastLine] do
    -- print(lastLine .. ":", tooltipLines[lastLine].leftText)

    -- Ignore class restriction lines by checking the line type.
    if tooltipLines[lastLine].type == Enum.TooltipDataLineType.RestrictedRaceClass then
      -- print("IGNORING")
      ingnoredLines = ingnoredLines + 1
    end

    lastLine = lastLine + 1
  end

  return lastLine - ingnoredLines - 1

end



local function AddSellPrice(tooltip)

  -- Quest reward item tooltips have no tooltip.
  if not tooltip.GetItem then return end

  local name, link = tooltip:GetItem()
  -- Just to be on the safe side...
  if not name or not link then return end

  local itemId = tonumber(string_match(link, "^.-:(%d+):"))

  -- These world quest rewards behave weirdly on world map tooltip. It is "no sell price" anyway.
  if itemId == 228361 or itemId == 235548 then return end

  local _, _, _, _, _, _, _, _, _, _, itemSellPrice, classID = GetItemInfo(link)


  -- Got a report that "Sell Price Per Unit" blocked using a quest item through the quest tracker:
  -- https://legacy.curseforge.com/wow/addons/sell-price-per-unit?comment=18
  -- Could not reproduce this, but I guess it does not hurt to exclued quest items.
  -- https://warcraft.wiki.gg/wiki/ItemType
  if classID == 12 then return end

  -- GetItemInfo() may return nil sometimes.
  -- https://wow.gamepedia.com/API_GetItemInfo
  if itemSellPrice == nil then return end


  -- Get the number of items in stack.
  -- Inspired by: https://www.wowinterface.com/downloads/info25078-BetterVendorPrice.html
  local stackCount = nil

  local focusFrame
  -- GetMouseFocus() was removed in 11.0.0.
  if GetMouseFoci then
    local focusFrames = GetMouseFoci()
    -- If we have no or more than one focus frame, something is not right...
    if focusFrames[1] == nil or focusFrames[2] ~= nil then return end
    focusFrame = focusFrames[1]
  else
    focusFrame = GetMouseFocus()
  end

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


  -- Flags to indicate whether we should inser money frame or unsellable label. (TODO: Really needed?)
  local insertNewMoneyFrame = false
  local insertUnsellable = false

  -- After which line should we insert the money frame or unsellable label?
  local insertAfterLine = nil


  -- If there is no money frame, we always add one.
  if not tooltip.shownMoneyFrames then

    -- print("No money frame")


    if itemSellPrice ~= 0 then

      -- print("itemSellPrice not zero", itemSellPrice)

      -- Before 10.0.2, we can just add the unsellable label, because due to our
      -- pre-hook we can be sure that we are the first added line.
      if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
        SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
        return

      -- After 10.0.2 we use GetLastTooltipLine().
      else

        -- If this is an item in the merchant frame, we just add the sell price now,
        -- Because GetLastTooltipLine() is too unreliable (see above).
        if merchantFrameOpen then
          local owner = tooltip:GetOwner()
          if owner and owner:GetObjectType() == "Button" and owner:GetParent():GetParent() == MerchantFrame then
            SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
            return
          end
        end

        insertNewMoneyFrame = true
        insertAfterLine = GetLastTooltipLine(itemId)

      end

    else

      -- print("itemSellPrice zero")

      -- When at a merchant, the bag items already get the unsellable label.
      -- So while we are at a merchant, we must not add the unsellable line to bag items;
      -- only to items in the merchant frame, which normally don't have these.
      if not merchantFrameOpen or (focusFrame and focusFrame:GetName() and string_find(focusFrame:GetName(), "^MerchantItem")) then

        -- Before 10.0.2, we can just add the unsellable label, because due to our
        -- pre-hook we can be sure that we are the first added line.
        if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
          tooltip:AddLine(ITEM_UNSELLABLE, 1, 1, 1, false)
          return

        -- After 10.0.2 we use GetLastTooltipLine().
        else

          -- If this is an item in the merchant frame, we just add the sell price now,
          -- Because GetLastTooltipLine() is too unreliable (see above).
          if merchantFrameOpen then
            local owner = tooltip:GetOwner()
            if owner and owner:GetObjectType() == "Button" and owner:GetParent():GetParent() == MerchantFrame then
              tooltip:AddLine(ITEM_UNSELLABLE, 1, 1, 1, false)
              return
            end
          end

          insertUnsellable = true
          insertAfterLine = GetLastTooltipLine(itemId)

        end

      end

    end
  end




  -- In classic, while you are at a merchant, the sell price is shown without the
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

    -- Happens when the Appearances->Sets tab is opened with BetterWardrobe running.
    if not _G[tooltip:GetName().."TextLeft"..i] or not _G[tooltip:GetName().."TextRight"..i] then return end

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

    if stackCount > 1 then
      SetTooltipMoney(tooltip, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
    end

    -- If this was no new money frame added, we skip the old money frame of the recorded lines.
    if not insertNewMoneyFrame then
      insertAfterLine = insertAfterLine + 1
    end
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

