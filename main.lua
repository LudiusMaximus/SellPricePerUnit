
local math_floor = _G.math.floor
local math_ceil  = _G.math.ceil
local select = _G.select
local string_find = _G.string.find
local string_format = _G.string.format
local string_gsub = _G.string.gsub
local string_match = _G.string.match
local tonumber = _G.tonumber

local GameTooltip = _G.GameTooltip
local GetBuildInfo = _G.GetBuildInfo
local GetMouseFoci = _G.GetMouseFoci
local MerchantFrame = _G.MerchantFrame

local C_Item_GetItemInfo = _G.C_Item.GetItemInfo
local C_Item_GetItemLocation = _G.C_Item.GetItemLocation

-- These are not there in classic.
local C_LegendaryCrafting_IsRuneforgeLegendary = C_LegendaryCrafting and _G.C_LegendaryCrafting.IsRuneforgeLegendary or nil
local C_TooltipInfo_GetItemByGUID = C_TooltipInfo and _G.C_TooltipInfo.GetItemByGUID or nil
local C_TooltipInfo_GetItemByID = C_TooltipInfo and _G.C_TooltipInfo.GetItemByID or nil
local issecretvalue = _G.issecretvalue or function() return false end

local SELL_PRICE = _G.SELL_PRICE
local AUCTION_PRICE_PER_ITEM = _G.AUCTION_PRICE_PER_ITEM
local ITEM_UNSELLABLE = _G.ITEM_UNSELLABLE
local LE_ITEM_CLASS_RECIPE = _G.LE_ITEM_CLASS_RECIPE
local LOCKED_WITH_ITEM = _G.LOCKED_WITH_ITEM


-- Insert new lines into a tooltip after a given line number, shifting subsequent
-- lines down.  All operations use C-side widget APIs (AddLine, SetText,
-- SetTextColor, Show/Hide) that do not perform Lua-side arithmetic and are
-- therefore taint-safe inside securecallfunction.
-- Unlike the old ClearLines()+rebuild approach, this preserves Blizzard's own
-- money frame untouched.
-- newLines: array of { text, r, g, b }
local function InsertTooltipLines(tooltip, insertPoint, newLines)
  local tooltipName = tooltip:GetName()
  local numLines = tooltip:NumLines()
  local insertCount = #newLines

  -- Store text, colours, and right-side state of lines that will shift down.
  local stored = {}
  for i = insertPoint + 1, numLines do
    local leftFS  = _G[tooltipName .. "TextLeft"  .. i]
    local rightFS = _G[tooltipName .. "TextRight" .. i]
    if not leftFS or not rightFS then return end
    local lr, lg, lb = leftFS:GetTextColor()
    local rr, rg, rb = rightFS:GetTextColor()
    stored[i] = {
      leftText   = leftFS:GetText(),
      lr = lr, lg = lg, lb = lb,
      rightText  = rightFS:GetText(),
      rightShown = rightFS:IsShown(),
      rr = rr, rg = rg, rb = rb,
    }
  end

  -- Add blank lines at the end to make room.
  for i = 1, insertCount do
    tooltip:AddLine(" ", 1, 1, 1, true)
  end

  -- Write new content at the insertion point.
  for i = 1, insertCount do
    local lineNum = insertPoint + i
    local line = newLines[i]
    local leftFS  = _G[tooltipName .. "TextLeft"  .. lineNum]
    local rightFS = _G[tooltipName .. "TextRight" .. lineNum]
    leftFS:SetText(line.text)
    leftFS:SetTextColor(line.r, line.g, line.b)
    rightFS:SetText("")
    rightFS:Hide()
  end

  -- Shift stored lines down by insertCount.
  for i = insertPoint + 1, numLines do
    local targetLine = i + insertCount
    local s = stored[i]
    local leftFS  = _G[tooltipName .. "TextLeft"  .. targetLine]
    local rightFS = _G[tooltipName .. "TextRight" .. targetLine]
    leftFS:SetText(s.leftText)
    leftFS:SetTextColor(s.lr, s.lg, s.lb)
    if s.rightText and s.rightShown then
      rightFS:SetText(s.rightText)
      rightFS:SetTextColor(s.rr, s.rg, s.rb)
      rightFS:Show()
    else
      rightFS:SetText("")
      rightFS:Hide()
    end
  end

  -- Force tooltip to recalculate its layout.
  tooltip:Show()
end


-- In retail (>= 10.0.2), we add our "Sell Price Per Unit" money line using
-- pre-created TooltipMoneyFrameTemplate frames.
--
-- THE PROBLEM:
-- Tooltip hooks registered via TooltipDataProcessor.AddTooltipPostCall fire
-- inside securecallfunction. When our addon previously called Blizzard's
-- SetTooltipMoney from this context, it ran MoneyFrame_Update in our addon's
-- tainted (insecure) execution context, which called SetWidth()/SetText() on
-- the GameTooltipMoneyFrame's coin buttons — tainting those widgets.
-- GameTooltipMoneyFrame objects persist in _G across tooltip displays.  On a
-- subsequent tooltip, Blizzard's own secure SellPrice handler reuses the same
-- frame and calls MoneyFrame_Update, which does layout math:
--       width = width + goldButton:GetWidth()        (MoneyFrame.lua:307)
-- goldButton:GetWidth() returns a secret ("tainted by SellPricePerUnit")
-- because the button was previously modified from our insecure context.
-- The arithmetic crashes: "attempt to perform arithmetic on a secret number".
--
-- THE FIX:
-- We never call SetTooltipMoney, so Blizzard's GameTooltipMoneyFrame stays
-- untouched.  Instead we:
-- * Pre-create our OWN TooltipMoneyFrameTemplate frames at addon LOAD TIME
--   (outside securecallfunction).
-- * Use SPPU_MoneyFrame_Update() which sets each coin button's width from
--   pre-measured values (measured at load time, untainted context), never
--   calling GetWidth()/GetTextWidth()/GetStringWidth() at runtime.
--   Buttons are anchored LEFT-to-RIGHT from the prefix text with SetPoint(),
--   avoiding Blizzard's RIGHT-to-LEFT width-accumulation arithmetic entirely.
-- * InsertMoneyLine inserts a blank line via InsertTooltipLines (for height)
--   and overlays the pre-created frame on it.  Tooltip minimum width is
--   computed from btn.Text:GetStringWidth() on each shown coin button,
--   guarded by issecretvalue().  If any measurement is secret, we fall back
--   to pre-measured component widths (prefix, coin text per digit count, icon).

-- Pre-create frames at load time using Blizzard's template.
local SPPU_POOL_SIZE = 3  -- max 2 per tooltip (total + per-unit) + 1 spare
local sppuFramePool = {}

if select(4, GetBuildInfo()) >= 100002 then
  for i = 1, SPPU_POOL_SIZE do
    local f = CreateFrame("Frame", "SPPUMoneyFrame" .. i, UIParent, "TooltipMoneyFrameTemplate")
    MoneyFrame_SetType(f, "STATIC")
    -- Prevent the template's OnShow from calling MoneyFrame_UpdateMoney ->
    -- MoneyFrame_Update, which uses GetWidth() and sets conflicting anchors.
    f:SetScript("OnShow", nil)
    -- SuffixText is a FontString that MoneyFrame_Update anchors after the copper
    -- button for optional trailing labels (e.g. "/week").  We never set one, so
    -- clear it once at creation to prevent stale text from ever appearing.
    if f.SuffixText then f.SuffixText:SetText("") end
    f:Hide()
    sppuFramePool[i] = f
  end
end

local function SPPU_AcquireFrame()
  for _, f in ipairs(sppuFramePool) do
    if not f:IsShown() then return f end
  end
  -- Safety fallback — should never happen with our pool size.
  local f = CreateFrame("Frame", "SPPUMoneyFrame" .. (#sppuFramePool + 1), UIParent, "TooltipMoneyFrameTemplate")
  MoneyFrame_SetType(f, "STATIC")
  f:SetScript("OnShow", nil)
  -- See pool creation above for why we clear SuffixText.
  if f.SuffixText then f.SuffixText:SetText("") end
  sppuFramePool[#sppuFramePool + 1] = f
  return f
end

-- Update coin buttons using LEFT-to-RIGHT relative anchoring.
local SPPU_PREFIX_XOFFSET = 4   -- matches SetTooltipMoney's xOffset
local SPPU_PREFIX_GAP     = 13  -- gap prefix→first coin (≈ iconWidth)
local SPPU_COIN_GAP       = 4   -- gap between denomination groups

-- Icon width for the SmallMoneyFrameTemplate coin buttons (MONEY_ICON_WIDTH_SMALL).
local SPPU_SMALL_ICON_WIDTH = 13

-- Pre-measured component widths for computing button sizes and tooltip minimum
-- width.  At runtime inside securecallfunction, our addon-created frames return
-- secret values from widget getters (GetStringWidth, GetWidth, etc.).  We
-- therefore cannot measure text widths live.  Instead we pre-measure them at
-- load time (outside securecallfunction — untainted context) and use the stored
-- values for SetWidth() in SPPU_MoneyFrame_Update and for computing tooltip
-- minimum width in SPPU_ComputeMinWidth.
--
-- All coin buttons use the same font, so a single button suffices for
-- measuring any denomination's text width.  Silver/copper are always 0–99,
-- so we measure the max ("99") once — slightly overestimates for 1-digit
-- values, but never underestimates.  Gold can be arbitrarily wide due to
-- BreakUpLargeNumbers (e.g. "1,234"), so we measure a representative value
-- for each formatted string length up to 999,999g.
local SPPU_PREFIX_TEXT_WIDTH = 0   -- width of per-unit prefix text
local SPPU_SC_TEXT_WIDTH     = 0   -- text width of "99" (max silver/copper)
local SPPU_SC_BUTTON_WIDTH   = 0   -- SPPU_SC_TEXT_WIDTH + SPPU_SMALL_ICON_WIDTH
local SPPU_GOLD_TEXT_WIDTH   = {}  -- gold text width keyed by formatted string length

if select(4, GetBuildInfo()) >= 100002 then
  local f = sppuFramePool[1]
  local prefix = string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM)
  f.PrefixText:SetText(prefix)
  SPPU_PREFIX_TEXT_WIDTH = f.PrefixText:GetStringWidth()

  -- All coin buttons share the same font — use any one for measurement.
  local btn = f.CopperButton
  btn.Text:SetText("99")
  SPPU_SC_TEXT_WIDTH = btn.Text:GetStringWidth()
  SPPU_SC_BUTTON_WIDTH = SPPU_SC_TEXT_WIDTH + SPPU_SMALL_ICON_WIDTH

  -- Gold: measure BreakUpLargeNumbers output for each formatted string length.
  -- 9 → "9" (1 char), 99 → "99" (2), 999 → "999" (3),
  -- 9999 → "9,999" (5), 99999 → "99,999" (6), 999999 → "999,999" (7).
  for _, g in ipairs({9, 99, 999, 9999, 99999, 999999}) do
    local s = BreakUpLargeNumbers(g)
    btn.Text:SetText(s)
    SPPU_GOLD_TEXT_WIDTH[#s] = btn.Text:GetStringWidth()
  end

  f.PrefixText:SetText("")
  btn.Text:SetText("")
  f:Hide()
end

local function SPPU_MoneyFrame_Update(frame, money, prefix)
  local gold   = math_floor(money / 10000)
  local silver = math_floor(money / 100) % 100
  local copper = money % 100

  -- Set prefix text.
  if frame.PrefixText then
    frame.PrefixText:SetText(prefix)
    frame.PrefixText:Show()
  end

  -- Configure coin buttons.
  local goldBtn   = frame.GoldButton
  local silverBtn = frame.SilverButton
  local copperBtn = frame.CopperButton

  if gold > 0 then
    local goldStr = BreakUpLargeNumbers(gold)
    goldBtn.Text:SetText(goldStr)
    -- Use pre-measured gold text width — GetStringWidth() returns a secret
    -- on addon-created frames inside securecallfunction.
    local tw = SPPU_GOLD_TEXT_WIDTH[#goldStr]
    if not tw then
      for _, w in pairs(SPPU_GOLD_TEXT_WIDTH) do
        if not tw or w > tw then tw = w end
      end
    end
    goldBtn:SetWidth(tw + SPPU_SMALL_ICON_WIDTH)
    goldBtn:Show()
  else
    goldBtn:Hide()
  end

  if silver > 0 then
    silverBtn.Text:SetText(silver)
    silverBtn:SetWidth(SPPU_SC_BUTTON_WIDTH)
    silverBtn:Show()
  else
    silverBtn:Hide()
  end

  if copper > 0 then
    copperBtn.Text:SetText(copper)
    copperBtn:SetWidth(SPPU_SC_BUTTON_WIDTH)
    copperBtn:Show()
  else
    copperBtn:Hide()
  end

  -- Blizzard's MoneyFrame_Update anchors RIGHT-to-LEFT: it pins copperButton to
  -- the frame's RIGHT edge, chains silver and gold leftward, then accumulates
  -- width via GetWidth() on each button (the line that crashes — see above).
  -- We anchor LEFT-to-RIGHT from PrefixText instead.  Our frame is pinned to
  -- tooltip's TextLeft by its LEFT edge, so the frame's right edge is irrelevant.
  -- Each button's width is set from pre-measured text widths (not live
  -- GetStringWidth(), which returns a secret on our addon-created frames)
  -- so the next button anchors correctly to the previous button's RIGHT edge.
  local prevAnchor = frame.PrefixText
  local gap = SPPU_PREFIX_GAP
  for _, btn in ipairs({ goldBtn, silverBtn, copperBtn }) do
    if btn:IsShown() then
      btn:ClearAllPoints()
      btn:SetPoint("LEFT", prevAnchor, "RIGHT", gap, 0)
      prevAnchor = btn
      gap = SPPU_COIN_GAP
    end
  end
end

-- Compute tooltip minimum width from pre-measured component widths.
-- Mirrors the live GetStringWidth() path but uses load-time measurements.
local function SPPU_ComputeMinWidth(gold, silver, copper)
  local total = SPPU_PREFIX_XOFFSET + SPPU_PREFIX_TEXT_WIDTH
  local gap = SPPU_PREFIX_GAP

  if gold > 0 then
    local goldStr = BreakUpLargeNumbers(gold)
    local tw = SPPU_GOLD_TEXT_WIDTH[#goldStr]
    if not tw then
      -- Gold has more digits than we pre-measured; use the widest known width.
      for _, w in pairs(SPPU_GOLD_TEXT_WIDTH) do
        if not tw or w > tw then tw = w end
      end
    end
    total = total + gap + tw + SPPU_SMALL_ICON_WIDTH
    gap = SPPU_COIN_GAP
  end

  if silver > 0 then
    total = total + gap + SPPU_SC_TEXT_WIDTH + SPPU_SMALL_ICON_WIDTH
    gap = SPPU_COIN_GAP
  end

  if copper > 0 then
    total = total + gap + SPPU_SC_TEXT_WIDTH + SPPU_SMALL_ICON_WIDTH
  end

  return math_ceil(total) + 20  -- +20 for tooltip left/right insets
end

-- Insert a properly-rendered money line at insertPoint in the tooltip.
-- InsertTooltipLines adds a blank " " line (for height) and shifts
-- subsequent lines down.  The SPPU frame overlays that blank line.
local function InsertMoneyLine(tooltip, insertPoint, money, prefix)
  local gold   = math_floor(money / 10000)
  local silver = math_floor(money / 100) % 100
  local copper = money % 100

  -- Acquire and populate the frame first so the coin button texts are set,
  -- letting us attempt to read their rendered string widths.
  local frame = SPPU_AcquireFrame()
  SPPU_MoneyFrame_Update(frame, money, prefix)

  -- Try to compute the actual displayed width from button text string widths,
  -- mirroring what MoneyFrame_Update does (textWidth + iconWidth per button).
  -- issecretvalue() guards every measurement; if any is secret (which happens
  -- on our addon-created frames inside securecallfunction) we fall back to
  -- pre-measured component widths from load time.
  local minWidth
  do
    local total  = SPPU_PREFIX_XOFFSET
    local secret = false

    if frame.PrefixText then
      local pw = frame.PrefixText:GetStringWidth()
      if issecretvalue(pw) then secret = true else total = total + pw end
    end

    if not secret then
      local gap = SPPU_PREFIX_GAP
      for _, btn in ipairs({ frame.GoldButton, frame.SilverButton, frame.CopperButton }) do
        if btn:IsShown() then
          local tw = btn.Text:GetStringWidth()
          if issecretvalue(tw) then secret = true; break end
          total = total + gap + tw + SPPU_SMALL_ICON_WIDTH
          gap = SPPU_COIN_GAP
        end
      end
    end

    if secret then
      minWidth = SPPU_ComputeMinWidth(gold, silver, copper)
      -- print("SPPU: secret width, fallback minWidth =", minWidth, "(gold="..gold..", silver="..silver..", copper="..copper..")")
    else
      minWidth = math_ceil(total) + 20  -- +20 for tooltip left/right insets
    end
  end

  tooltip:SetMinimumWidth(minWidth)
  InsertTooltipLines(tooltip, insertPoint, {{ text = " ", r = 1, g = 1, b = 1 }})
  local lineNum = insertPoint + 1
  frame:SetParent(tooltip)
  frame:ClearAllPoints()
  frame:SetPoint("LEFT", _G[tooltip:GetName() .. "TextLeft" .. lineNum], "LEFT", SPPU_PREFIX_XOFFSET, 0)
  frame:Show()
  -- Register for cleanup via SharedTooltip_ClearInsertedFrames.
  if not tooltip.insertedFrames then tooltip.insertedFrames = {} end
  tinsert(tooltip.insertedFrames, frame)
end

-- Text-based fallback using AddLine + atlas markup — used for the merchant
-- fast-path (MerchantFrame) where we just append at the end.
local ICON_SIZE = 13

local function FormatMoneyAtlas(money)
  local gold = math_floor(money / 10000)
  local silver = math_floor(money / 100) % 100
  local copper = money % 100

  local parts = {}
  if gold > 0 then
    parts[#parts + 1] = BreakUpLargeNumbers(gold) .. CreateAtlasMarkup("coin-gold", ICON_SIZE, ICON_SIZE)
  end
  if silver > 0 then
    parts[#parts + 1] = silver .. CreateAtlasMarkup("coin-silver", ICON_SIZE, ICON_SIZE)
  end
  if copper > 0 or #parts == 0 then
    parts[#parts + 1] = copper .. CreateAtlasMarkup("coin-copper", ICON_SIZE, ICON_SIZE)
  end

  return table.concat(parts, " ")
end

local function AddMoneyLine(tooltip, money, prefix)
  tooltip:AddLine(prefix .. "   " .. FormatMoneyAtlas(money), 1, 1, 1, false)
end


-- Normally, we want the money frame or unsellable label to appear in the tooltip
-- at the bottom of the all other WoW stock tooltip lines; i.e. before any other addon
-- has added further lines to the tooltip.
-- Before 10.0.2 this was able with a pre-hook.
-- After 10.0.2, we try to determine the tooltip line after which to insert
-- by the number of lines returned by GetItemByGUID (or GetItemByID).
-- This works OK for bag items (except that class restriction lines may be ommitted in the actual tooltip).
-- For items sold in a merchant frame, it not good enough! Because the actual tooltip can have so many
-- more lines added to the stock tooltip, which are not returned by GetItemByGUID
-- (e.g. Renown required, Season, Upgrade Level, "Shift click to by a different amount").
-- Taking care of all these special cases would be too much of a pain for the little gain.
-- We prefer GUID, as it gives the more realistic tooltip. (E.g. for Shadowlands Crafted Legendaries it
-- shows the tooltip of the enchantment and not just that of the base item. Also RestrictedRaceClass lines
-- are already removed, so we do not have to manually ignore them.
-- We just use itemId as a fallback.
local function GetLastTooltipLine(guid, itemId)

  local tooltipLines = nil

  if guid then
    -- Get the base, unmodified tooltip using the item's GUID.
    local baseTooltipData = C_TooltipInfo_GetItemByGUID(guid)
    if baseTooltipData then
      tooltipLines = baseTooltipData.lines
    else
      -- Flag to enable ignoring below.
      guid = nil
    end
  end

  -- Fallback, e.g. for cached bank items of Baganator, Bagnon, ...
  -- for which we can get neither guid nor location.
  if not tooltipLines and itemId then
    tooltipLines = C_TooltipInfo_GetItemByID(itemId).lines
  end


  local lastLine = 1
  local ingnoredLines = 0
  while tooltipLines[lastLine] do
    -- print(lastLine .. ":", tooltipLines[lastLine].leftText)

    -- If this tooltip was not created from GUID, we have to ignore class restriction lines by checking the line type.
    if not guid and tooltipLines[lastLine].type == Enum.TooltipDataLineType.RestrictedRaceClass then
      -- print("IGNORING")
      ingnoredLines = ingnoredLines + 1
    end

    lastLine = lastLine + 1
  end

  return lastLine - ingnoredLines - 1

end


-- Some items have a sell price, yet no vendor buys them.
-- (*) Correctly has no sell price, yet the game shows no unsellable label while at vendors.
local fixUnsellableItems = {
  [204790] = true,    -- Strong Sniffin' Soup for Niffen
  [210814] = true,    -- (*) Artisan's Acuity
  [211297] = true,    -- Fractured Spark of Omens
  [220152] = true,    -- Cursed Ghoulfish
  [223901] = true,    -- (*) Violet Silk Scrap
  [223902] = true,    -- (*) Crimson Silk Scrap
  [223903] = true,    -- (*) Gold Silk Scrap
  [224185] = true,    -- (*) Crab-Guiding Branch
  [224818] = true,    -- (*) Algari Miner's Notes
  [226362] = true,    -- Torn Note
  [230905] = true,    -- Fractured Spark of Fortunes
  [236096] = true,    -- (*) Coffer Key Shard
}


-- Function to check if an item is a Shadowlands legendary.
-- Because these have a sell price even though they are not sellable.
local function IsRuneforgeLegendary(guid)

  -- If we are pre-Shadowlands.
  if not C_LegendaryCrafting_IsRuneforgeLegendary then return false end

  if not guid then return false end

  -- Get item location from the GUID.
  local itemLocation = C_Item_GetItemLocation(guid)

  -- Vendor buyback items return an invalid itemLocation.
  -- Trying to check these with itemLocation:IsValid() already throws an error.
  -- So, we check if GetBagAndSlot returns nil.
  if not itemLocation or itemLocation:GetBagAndSlot() == nil then return false end

  -- Check if it is a runeforged legendary.
  return C_LegendaryCrafting_IsRuneforgeLegendary(itemLocation)
end


-- Check if there's a text-based sell price line (e.g. from Baganator)
local function HasTextBasedSellPrice(tooltip)
  for i = 1, tooltip:NumLines() do
    local line = _G[tooltip:GetName().."TextLeft"..i]
    if line then
      local text = line:GetText()
      if text then
        -- Strip color codes before checking (|cXXXXXXXX at start, |r at end)
        local strippedText = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if strippedText:match("^"..SELL_PRICE) then
          return i
        end
      end
    end
  end
  return nil
end


local function AddSellPrice(tooltip, tooltipData)

  -- For tooltips without money frame, we try to add one. But determining the
  -- correct price for GameTooltipTooltip (i.e. tooltips within the normal tooltip,
  -- e.g. world quest rewards) is error-prone.
  -- Some tooltips even lead to crashes (itemId == 228361 or itemId == 235548),
  -- which actually are in UIWidgetBaseItemEmbeddedTooltip1.
  -- So we exclude these altogether.
  -- print(tooltip:GetName())
  if tooltip == GameTooltipTooltip or tooltip == UIWidgetBaseItemEmbeddedTooltip1 then return end

  -- Got a report that "Sell Price Per Unit" blocked using a quest item through the quest tracker:
  -- https://legacy.curseforge.com/wow/addons/sell-price-per-unit?comment=18
  -- I could not reproduce this, but I guess exclueding QuestObjectiveTracker items does not hurt.
  local owner = tooltip:GetOwner()
  if owner and owner.GetParent then
    local ownerParent = owner:GetParent()
    if ownerParent and ownerParent.GetParent and ownerParent:GetParent() == QuestObjectiveTracker then
      -- print("Skipping QuestObjectiveTracker")
      return
    end
  end

  -- Quest reward item tooltips have no tooltip.
  if not tooltip.GetItem then return end
  local _, link = tooltip:GetItem()
  if not link then return end


  -- No tooltipData in classic.
  local itemId = tooltipData and tooltipData.id or nil
  -- Fallback.
  if not itemId then
    itemId = tonumber(string_match(link, "^.-:(%d+):"))
  end

  -- print(itemId, C_Item_GetItemInfo(link))


  local _, _, itemQuality, _, _, _, _, _, _, _, itemSellPrice, _, _, _, expansionId = C_Item_GetItemInfo(link)

  -- GetItemInfo() may return nil sometimes.
  -- https://warcraft.wiki.gg/wiki/API_C_Item.GetItemInfo
  if itemSellPrice == nil then return end


  local fixUnsellable = false

  -- Before 10.0.2, there was no tooltipData.
  -- TODO: See you for Shadowlands Classic to find a way to determine IsRuneforgeLegendary without it.
  if select(4, GetBuildInfo()) >= 100002 then

    -- If it is a Shadowlands Legendary and we have no GUID to make sure whether it is a Crafted Legendary, we abort.
    -- Because GetLastTooltipLine() cannot determine the correct insertAfterLine for these without GUID.
    if expansionId == 8 and itemQuality == 5 and not tooltipData.guid then
      -- print("Skipping unidentifiable Shadowlands Legendary!")
      return
    end

    -- itemQuality == 6 is for Artifact items, which have a price but are not sellable.
    if itemQuality == 6 or fixUnsellableItems[itemId] or IsRuneforgeLegendary(tooltipData.guid) then
      fixUnsellable = true
    end

  end


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

  -- DevTools_Dump(focusFrame)
  if focusFrame then
    if not focusFrame.hasItem then
      -- This should help to exclude bad frames, e.g. WoW token in the shop UI.
      return
    elseif focusFrame.count then
      stackCount = focusFrame.count
    -- Needed for Bagnon cached Bagnon items.
    elseif focusFrame:GetParent() and focusFrame:GetParent().count then
      stackCount = focusFrame:GetParent().count
    end
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


  -- Need this several times below.
  local merchantFrameOpen = MerchantFrame and MerchantFrame:IsShown()


  -- Flags to indicate whether we should insert sell price or unsellable label. (TODO: Really needed?)
  local insertNewSellPrice = false
  local insertUnsellable = false

  -- After which line should we insert the money frame or unsellable label?
  local insertAfterLine = nil


  -- Check if there's a text-based sell price (e.g. from Baganator)
  local textSellPriceLine = HasTextBasedSellPrice(tooltip)
  
  -- If there's a text-based sell price, add text-based per-unit line if needed
  if textSellPriceLine then
    if stackCount == 1 then
      -- Single item with text-based sell price already present, nothing to do
      return
    end
    
    -- For stacks, we need to insert the per-unit line right after the sell price line
    insertAfterLine = textSellPriceLine
  end

  -- If there is no money frame, we always add one.
  if not tooltip.shownMoneyFrames then

    -- print("No money frame")

    if itemSellPrice == 0 or fixUnsellable then

      -- print("itemSellPrice zero")

      -- When at a merchant, (most) bag items already get the unsellable label (except the "fixUnsellable" ones).
      -- So while we are at a merchant, we must not add the unsellable line to bag items;
      -- only to items in the merchant frame, which normally don't have these.
      if not merchantFrameOpen or fixUnsellable or (focusFrame and focusFrame:GetName() and string_find(focusFrame:GetName(), "^MerchantItem")) then

        -- Before 10.0.2, we can just add the unsellable label, because due to our
        -- pre-hook we can be sure that we are the first added line.
        if select(4, GetBuildInfo()) < 100002 then
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
          insertAfterLine = GetLastTooltipLine(tooltipData.guid, itemId)

        end

      end

    else

      -- print("itemSellPrice not zero", itemSellPrice)

      -- Before 10.0.2, we can just add the money frame, because due to our
      -- pre-hook we can be sure that we are the first added line.
      if select(4, GetBuildInfo()) < 100002 then
        SetTooltipMoney(tooltip, itemSellPrice*stackCount, nil, string_format("%s:", SELL_PRICE))
        if stackCount > 1 then
          SetTooltipMoney(tooltip, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
        end
        return

      -- After 10.0.2 we use GetLastTooltipLine().
      else

        -- If this is an item in the merchant frame, we just add the sell price now,
        -- Because GetLastTooltipLine() is too unreliable (see above).
        if merchantFrameOpen then
          local owner = tooltip:GetOwner()
          if owner and owner:GetObjectType() == "Button" and owner:GetParent():GetParent() == MerchantFrame then
            AddMoneyLine(tooltip, itemSellPrice*stackCount, string_format("%s:", SELL_PRICE))
            if stackCount > 1 then
              AddMoneyLine(tooltip, itemSellPrice, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
            end
            return
          end
        end

        insertNewSellPrice = true
        insertAfterLine = GetLastTooltipLine(tooltipData.guid, itemId)

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


  if insertUnsellable then
    -- Unsellable label is plain text — use InsertTooltipLines.
    InsertTooltipLines(tooltip, insertAfterLine, {{ text = ITEM_UNSELLABLE, r = 1, g = 1, b = 1 }})

  elseif textSellPriceLine then
    -- Per-unit line for Baganator's text-based sell price.
    if select(4, GetBuildInfo()) < 100002 then
      SetTooltipMoney(tooltip, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
    else
      InsertMoneyLine(tooltip, insertAfterLine, itemSellPrice, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
    end

  else
    -- When Blizzard has a money frame, skip its blank line so we insert after it.
    if not insertNewSellPrice then
      insertAfterLine = insertAfterLine + 1
    else
      -- We are adding a new sell price (Blizzard didn't show one).
      if select(4, GetBuildInfo()) < 100002 then
        SetTooltipMoney(tooltip, itemSellPrice * stackCount, nil, string_format("%s:", SELL_PRICE))
      else
        InsertMoneyLine(tooltip, insertAfterLine, itemSellPrice * stackCount, string_format("%s:", SELL_PRICE))
      end
      insertAfterLine = insertAfterLine + 1
    end
    if stackCount > 1 then
      if select(4, GetBuildInfo()) < 100002 then
        SetTooltipMoney(tooltip, itemSellPrice, nil, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
      else
        InsertMoneyLine(tooltip, insertAfterLine, itemSellPrice, string_format("%s %s:", SELL_PRICE, AUCTION_PRICE_PER_ITEM))
      end
    end
  end

end




-- After 10.0.2 we have to use this to alter the tooltip.
if select(4, GetBuildInfo()) >= 100002 then
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

      local _, link = self:GetItem()
      if not link then return RunOtherScripts(self, ...) end

      local _, _, _, _, _, _, _, _, _, _, _, itemTypeId, itemSubTypeId = C_Item_GetItemInfo(link)

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
  -- Because other addons (like BagSync) may use an attribute that tracks
  -- which call of OnTooltipSetItem() they are on.
  -- Therefore take this timer!
  local startupFrame = CreateFrame("Frame")
  startupFrame:RegisterEvent("PLAYER_LOGIN")
  startupFrame:SetScript("OnEvent", function(self, event, ...)
    C_Timer.After(3.0, initCode)
  end)

end

