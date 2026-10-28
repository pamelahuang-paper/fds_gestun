"""Does a company's invoice text describe the business it declared?

The invoice_matching project reads a company's invoice line items and says what
business it looks like (`my_sector`, its own English vocabulary). paper.id holds
what the company said at onboarding (`business_type_child_name`, Indonesian).
Neither is a controlled vocabulary shared with the other, so a verdict needs
both mapped onto one coarse taxonomy. That mapping is SECTOR and DECLARED below.

Why this matters for gestun: a cash-out operation needs invoices to justify the
card charges, and inventing them is easier than running the business. When the
line items describe a different trade from the one declared, that is a reason to
look. It is a signal, not proof -- a company can diversify, change trade, or
have picked the wrong dropdown at signup.

The verdict is deliberately three-valued. UNKNOWN is not a soft MISMATCH: it
means the invoices were too thin or too generic to read, which is its own
observation and must not be scored as disagreement.
"""

from __future__ import annotations

import pandas as pd

# Coarse taxonomy. Deliberately blunt: the question is "same trade or not",
# and a finer grid turns ordinary breadth into false mismatches.
APPAREL      = "apparel & textile"
FOOD         = "food & beverage"
FMCG         = "everyday goods"
TELECOM      = "telecom & mobile"
ELECTRONICS  = "electronics & IT"
JEWELLERY    = "jewellery & precious"
AGRI         = "agriculture & livestock"
CONSTRUCTION = "construction & property"
HOME         = "home & furniture"
AUTOMOTIVE   = "automotive"
BEAUTY       = "beauty & personal care"
HEALTH       = "health & medical"
TRAVEL       = "travel & tourism"
EVENTS       = "events & entertainment"
INDUSTRIAL   = "industrial & chemical"
MEDIA        = "media, print & advertising"
SERVICES     = "business & professional services"
FINANCE      = "finance & investment"
EDUCATION    = "education"
LOGISTICS    = "logistics & transport"
TOYS         = "toys, hobby & collectibles"
SPORT        = "sport & outdoor"
GENERAL      = "general / mixed trading"

# invoice_matching's `my_sector` -> taxonomy
SECTOR = {
    "Apparel": APPAREL, "Apparel retail": APPAREL, "Apparel wholesale": APPAREL,
    "Apparel manufacturing": APPAREL, "Textile": APPAREL, "Textile retail": APPAREL,
    "Textile supply": APPAREL, "Textile services": APPAREL, "Footwear": APPAREL,
    "Leather goods": APPAREL, "Merchandise": APPAREL,
    "Food manufacturing": FOOD, "Food service": FOOD, "Tobacco": FOOD,
    "FMCG distribution": FMCG, "FMCG retail": FMCG, "Retail kiosk": FMCG,
    "Housewares": HOME, "Furniture": HOME, "Water supply": HOME,
    "Mobile retail": TELECOM, "Mobile parts": TELECOM, "Telecom": TELECOM,
    "Electronics retail": ELECTRONICS, "IT services": ELECTRONICS,
    "IT infrastructure": ELECTRONICS, "Gaming": ELECTRONICS,
    "Security systems": ELECTRONICS,
    "Jewellery": JEWELLERY, "Jewellery & watches": JEWELLERY, "Luxury resale": JEWELLERY,
    "Agriculture trading": AGRI, "Aquaculture": AGRI, "Livestock": AGRI,
    "Pets": AGRI, "Pets & aquaculture": AGRI,
    "Building materials": CONSTRUCTION, "Construction": CONSTRUCTION,
    "Construction / landscaping": CONSTRUCTION, "Hardware": CONSTRUCTION,
    "Automotive": AUTOMOTIVE, "Automotive parts": AUTOMOTIVE,
    "Automotive accessories": AUTOMOTIVE, "Automotive workshop": AUTOMOTIVE,
    "Transport rental": AUTOMOTIVE,
    "Beauty": BEAUTY, "Beauty equipment": BEAUTY, "Baby care": BEAUTY,
    "Healthcare supply": HEALTH, "Medical diagnostics": HEALTH,
    "Traditional medicine": HEALTH,
    "Travel": TRAVEL,
    "Events": EVENTS, "Personal shopping / events": EVENTS,
    "Industrial components": INDUSTRIAL, "Industrial equipment": INDUSTRIAL,
    "Plastics": INDUSTRIAL, "Packaging": INDUSTRIAL, "Energy / mixed": INDUSTRIAL,
    "Printing": MEDIA, "Advertising": MEDIA,
    "Repair services": SERVICES, "Administrative services": SERVICES,
    "Professional services": SERVICES, "Direct selling": SERVICES,
    "Personal shopping": SERVICES,
    "Financial services": FINANCE, "Investment products": FINANCE,
    "Education": EDUCATION,
    "Logistics": LOGISTICS,
    "Collectibles": TOYS,
    "Sporting goods": SPORT,
    # these are the absence of a verdict, not a sector
    "General trading": GENERAL, "Mixed": GENERAL, "Mixed retail": GENERAL,
    "Unknown": None,
}

# paper.id's declared `business_type_child_name` -> taxonomy
DECLARED = {
    "PAKAIAN & AKSESORIS": APPAREL, "PAKAIAN & TEKSTIL": APPAREL,
    "TEKSTIL & KULIT": APPAREL, "KONVEKSI": APPAREL, "TAS & DOMPET": APPAREL,
    "MAKANAN & MINUMAN": FOOD, "BOGA & KULINER": FOOD,
    "KEBUTUHAN SEHARI-HARI": FMCG, "FRANCHISE": FMCG, "KEBERSIHAN": FMCG,
    "PERALATAN RUMAH & TAMAN": HOME, "FURNITUR PERABOT": HOME,
    "TELEKOMUNIKASI": TELECOM, "JASA TELEKOMUNIKASI": TELECOM,
    "KOMPUTER": ELECTRONICS, "ALAT ELEKTRONIK": ELECTRONICS,
    "ALAT ELEKTRONIK, KOMPUTER & GADGET": ELECTRONICS,
    "IT & SEKURITAS SISTEM": ELECTRONICS, "PRODUK DIGITAL": ELECTRONICS,
    "EMAS & PERHIASAN": JEWELLERY,
    "PERTANIAN, PERKEBUNAN & PETERNAKAN": AGRI,
    "KONSTRUKSI & PROPERTI": CONSTRUCTION,
    "KONSTRUKSI, ARSITEKTUR & DESAIN INTERIOR": CONSTRUCTION,
    "DESAIN INTERIOR & EXTERIOR": CONSTRUCTION, "ALAT BERAT": CONSTRUCTION,
    "OTOMOTIF & AKSESORIS": AUTOMOTIVE,
    "BENGKEL, MEKANIKAL & MAINTENANCE": AUTOMOTIVE,
    "ALAT MEKANIK & SUKU CADANG": AUTOMOTIVE,
    "PERAWATAN DIRI & KECANTIKAN": BEAUTY,
    "KESEHATAN & MEDIS": HEALTH,
    "PARIWISATA, TOUR & TRAVEL": TRAVEL, "TOUR & TRAVEL": TRAVEL,
    "EVENT & WEDDING ORGANIZER": EVENTS, "OLAHRAGA & HIBURAN": SPORT,
    "ALAT INDUSTRI": INDUSTRIAL, "BAHAN KIMIA": INDUSTRIAL,
    "KARET & PLASTIK": INDUSTRIAL, "ENERGI": INDUSTRIAL,
    "PERDAGANGAN TEKNIK": INDUSTRIAL,
    "MEDIA & ADVERTISING": MEDIA, "PERCETAKAN & PENGEMASAN": MEDIA,
    "JASA PERANTARA": SERVICES, "JASA SEWA/ RENTAL": SERVICES,
    "PENERJEMAHAN & SUNTING": SERVICES, "ORGANISASI SOSIAL & NIRLABA": SERVICES,
    "KEUANGAN, BISNIS & INVESTASI": FINANCE,
    "PELATIHAN, PENDIDIKAN & EDUKASI": EDUCATION,
    "MAINAN & HOBBY": TOYS, "KADO, SOUVENIR & HAMPERS": TOYS,
}

# Pairs that are not the same taxonomy group but are not evidence of anything.
# Adjacent trades: the same shop plausibly sells both, so a difference here is
# ordinary breadth rather than a company describing a business it is not in.
ADJACENT = {
    frozenset({APPAREL, SPORT}),         # sportswear
    frozenset({APPAREL, TOYS}),          # merch, souvenirs
    frozenset({APPAREL, BEAUTY}),        # lifestyle retail
    frozenset({FMCG, FOOD}),             # sembako / groceries
    frozenset({FMCG, HOME}),             # household goods
    frozenset({FMCG, BEAUTY}),           # toiletries
    frozenset({ELECTRONICS, TELECOM}),   # phones and computers
    frozenset({HOME, CONSTRUCTION}),     # fit-out and materials
    frozenset({INDUSTRIAL, CONSTRUCTION}),
    frozenset({AUTOMOTIVE, INDUSTRIAL}), # parts and machining
    frozenset({AGRI, FOOD}),             # farm to product
    frozenset({HEALTH, BEAUTY}),
    frozenset({EVENTS, MEDIA}),
    frozenset({EVENTS, TRAVEL}),
    frozenset({SERVICES, FINANCE}),
    frozenset({TOYS, SPORT}),
}

MATCH, ADJACENT_V, MISMATCH, UNREADABLE, NO_DECLARED = (
    "match", "adjacent", "MISMATCH", "unreadable", "no declared type")


def verdict(my_sector: str | None, declared: str | None) -> str:
    """One company's invoice-vs-declared verdict."""
    s = SECTOR.get(str(my_sector).strip()) if pd.notna(my_sector) else None
    d_raw = str(declared).strip() if pd.notna(declared) else ""
    if d_raw in ("", "(blank)", "nan", "EMPTY", "SKIP", "LAINNYA"):
        return NO_DECLARED
    d = DECLARED.get(d_raw)
    if s is None or s == GENERAL:
        # Unknown sector, or invoices that read as undifferentiated trading.
        return UNREADABLE
    if d is None:
        return UNREADABLE          # declared value outside the mapping
    if s == d:
        return MATCH
    if frozenset({s, d}) in ADJACENT:
        return ADJACENT_V
    return MISMATCH


def apply(frame: pd.DataFrame,
          sector_col: str = "my_sector",
          declared_col: str = "paper_business_type") -> pd.DataFrame:
    """Add invoice_sector, declared_sector and invoice_verdict columns."""
    out = frame.copy()
    out["invoice_sector"] = out[sector_col].map(
        lambda v: SECTOR.get(str(v).strip()) if pd.notna(v) else None)
    out["declared_sector"] = out[declared_col].map(
        lambda v: DECLARED.get(str(v).strip()) if pd.notna(v) else None)
    out["invoice_verdict"] = [
        verdict(s, d) for s, d in zip(out[sector_col], out[declared_col])]
    return out
