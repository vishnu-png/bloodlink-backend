-- =============================================================================
-- BloodLink AI - Complete Production Database Schema & Security Architecture
-- Target: PostgreSQL / Supabase
-- Modules: Auth, Roles, Donors, Hospitals, Blood Banks, Inventory, Requests,
--          AI Matching, Calendar, Audit Logs & Triggers
-- =============================================================================

-- Enable required cryptographic and spatial extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- 1. ENUMS & DOMAINS
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('donor', 'patient', 'hospital', 'blood_bank', 'admin');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE blood_group_enum AS ENUM ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE urgency_level AS ENUM ('low', 'medium', 'high', 'critical');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE request_status AS ENUM ('pending', 'matched', 'allocated', 'in_transit', 'completed', 'cancelled', 'expired');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE donor_response_status AS ENUM ('sent', 'accepted', 'declined', 'timeout', 'completed');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- -----------------------------------------------------------------------------
-- 2. CORE PROFILES TABLE (Supabase auth.users synchronization)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    full_name TEXT NOT NULL,
    role user_role NOT NULL DEFAULT 'donor',
    phone TEXT DEFAULT '',
    city TEXT DEFAULT 'Chennai',
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 3. ROLE-SPECIFIC TABLES
-- -----------------------------------------------------------------------------

-- A. Donor Profiles & Medical Details
CREATE TABLE IF NOT EXISTS public.donor_profiles (
    id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    blood_group blood_group_enum NOT NULL DEFAULT 'O+',
    last_donation_date DATE,
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    total_donations INTEGER NOT NULL DEFAULT 0,
    health_notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- B. Hospitals & Trauma Centers
CREATE TABLE IF NOT EXISTS public.hospitals (
    id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    hospital_name TEXT NOT NULL,
    license_number TEXT NOT NULL,
    emergency_contact TEXT NOT NULL,
    address TEXT,
    city TEXT DEFAULT 'Chennai',
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    verification_status TEXT NOT NULL DEFAULT 'verified',
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- C. Blood Banks & Cold Storage Vaults
CREATE TABLE IF NOT EXISTS public.blood_banks (
    id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    bank_name TEXT NOT NULL,
    license_number TEXT NOT NULL,
    contact_phone TEXT NOT NULL,
    address TEXT,
    city TEXT DEFAULT 'Chennai',
    storage_capacity_units INTEGER NOT NULL DEFAULT 500,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    verification_status TEXT NOT NULL DEFAULT 'verified',
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 4. BLOOD INVENTORY & FEFO EXPIRY TRACKING
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.blood_inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blood_bank_id UUID REFERENCES public.blood_banks(id) ON DELETE CASCADE,
    blood_group blood_group_enum NOT NULL,
    component_type TEXT NOT NULL DEFAULT 'whole_blood', -- whole_blood, packed_rbc, platelets, plasma
    units_available INTEGER NOT NULL DEFAULT 0,
    units_reserved INTEGER NOT NULL DEFAULT 0,
    storage_temp_celsius NUMERIC(4, 2) DEFAULT 4.0,
    expiry_date DATE NOT NULL,
    batch_number TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 5. EMERGENCY BLOOD REQUISITIONS & ALLOCATIONS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.blood_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL,
    patient_name TEXT NOT NULL,
    blood_group blood_group_enum NOT NULL,
    component_type TEXT NOT NULL DEFAULT 'whole_blood',
    units_requested INTEGER NOT NULL DEFAULT 1,
    units_allocated_inventory INTEGER NOT NULL DEFAULT 0,
    units_allocated_donors INTEGER NOT NULL DEFAULT 0,
    urgency urgency_level NOT NULL DEFAULT 'high',
    delivery_address TEXT NOT NULL,
    status request_status NOT NULL DEFAULT 'pending',
    required_within_hours INTEGER NOT NULL DEFAULT 6,
    is_closed BOOLEAN NOT NULL DEFAULT FALSE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 6. DONOR DISPATCH RESPONSES & AI MATCH SCORES
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.donor_responses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID REFERENCES public.blood_requests(id) ON DELETE CASCADE,
    donor_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    ml_predicted_prob NUMERIC(5, 4) DEFAULT 0.8500,
    status donor_response_status NOT NULL DEFAULT 'sent',
    dispatched_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    responded_at TIMESTAMPTZ,
    arrival_eta_minutes INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 7. DONOR AVAILABILITY CALENDAR & DONATION HISTORY
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.donor_availability_calendar (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    donor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    available_date DATE NOT NULL,
    time_slot TEXT NOT NULL DEFAULT 'ANYTIME', -- 'MORNING', 'AFTERNOON', 'EVENING', 'ANYTIME'
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    UNIQUE(donor_id, available_date)
);

CREATE TABLE IF NOT EXISTS public.donation_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    donor_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    donation_date DATE NOT NULL,
    units_donated INTEGER NOT NULL DEFAULT 1,
    blood_bank_id UUID REFERENCES public.blood_banks(id) ON DELETE SET NULL,
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL,
    certificate_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 8. AI DEFICIT FORECASTING & REAL-TIME ML METRICS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.shortage_forecasts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blood_group blood_group_enum NOT NULL,
    region TEXT NOT NULL DEFAULT 'Chennai Metropole',
    forecast_days INTEGER NOT NULL DEFAULT 7,
    projected_demand INTEGER NOT NULL DEFAULT 0,
    projected_supply INTEGER NOT NULL DEFAULT 0,
    shortage_risk_level TEXT NOT NULL DEFAULT 'MODERATE', -- LOW, MODERATE, HIGH, CRITICAL
    confidence_score NUMERIC(5, 4) DEFAULT 0.9200,
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 9. NOTIFICATIONS & AUDIT LOGS
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'emergency',
    is_read BOOLEAN NOT NULL DEFAULT FALSE,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    reference_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- -----------------------------------------------------------------------------
-- 10. REAL-TIME ROW LEVEL SECURITY (RLS) POLICIES
-- -----------------------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.donor_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blood_banks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blood_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blood_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.donor_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.donor_availability_calendar ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.donation_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shortage_forecasts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Production Access Policies
CREATE POLICY "profiles_all_access" ON public.profiles FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "donor_profiles_all_access" ON public.donor_profiles FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "hospitals_all_access" ON public.hospitals FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "blood_banks_all_access" ON public.blood_banks FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "blood_inventory_all_access" ON public.blood_inventory FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "blood_requests_all_access" ON public.blood_requests FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "donor_responses_all_access" ON public.donor_responses FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "calendar_all_access" ON public.donor_availability_calendar FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "donation_history_all_access" ON public.donation_history FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "shortage_forecasts_all_access" ON public.shortage_forecasts FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "notifications_all_access" ON public.notifications FOR ALL USING (true) WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- 11. AUTOMATED SUPABASE CLOUD AUTH TRIGGER (REAL-TIME PROFILE SYNC)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_auth_user_to_profile()
RETURNS TRIGGER AS $$
DECLARE
    v_role user_role := 'donor';
    v_role_str text;
    v_full_name text;
    v_phone text;
    v_city text;
    v_bg blood_group_enum := 'O+';
    v_bg_str text;
BEGIN
    v_role_str := LOWER(COALESCE(NEW.raw_user_meta_data->>'role', 'donor'));
    IF v_role_str IN ('donor', 'patient', 'hospital', 'blood_bank', 'admin') THEN
        v_role := v_role_str::user_role;
    END IF;

    v_full_name := COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1));
    v_phone := COALESCE(NEW.raw_user_meta_data->>'phone', '');
    v_city := COALESCE(NEW.raw_user_meta_data->>'city', 'Chennai');

    v_bg_str := COALESCE(NEW.raw_user_meta_data->>'blood_group', 'O+');
    IF v_bg_str IN ('O_POS', 'O+') THEN v_bg := 'O+';
    ELSIF v_bg_str IN ('O_NEG', 'O-') THEN v_bg := 'O-';
    ELSIF v_bg_str IN ('A_POS', 'A+') THEN v_bg := 'A+';
    ELSIF v_bg_str IN ('A_NEG', 'A-') THEN v_bg := 'A-';
    ELSIF v_bg_str IN ('B_POS', 'B+') THEN v_bg := 'B+';
    ELSIF v_bg_str IN ('B_NEG', 'B-') THEN v_bg := 'B-';
    ELSIF v_bg_str IN ('AB_POS', 'AB+') THEN v_bg := 'AB+';
    ELSIF v_bg_str IN ('AB_NEG', 'AB-') THEN v_bg := 'AB-';
    END IF;

    -- Upsert profile
    INSERT INTO public.profiles (id, email, full_name, role, phone, city, is_active)
    VALUES (NEW.id, NEW.email, v_full_name, v_role, v_phone, v_city, TRUE)
    ON CONFLICT (id) DO UPDATE SET
        full_name = EXCLUDED.full_name,
        role = EXCLUDED.role,
        phone = EXCLUDED.phone,
        city = EXCLUDED.city;

    -- Auto-provision role specific table records
    IF v_role = 'donor' THEN
        INSERT INTO public.donor_profiles (id, blood_group, is_available)
        VALUES (NEW.id, v_bg, TRUE)
        ON CONFLICT (id) DO UPDATE SET blood_group = EXCLUDED.blood_group;
    ELSIF v_role = 'hospital' THEN
        INSERT INTO public.hospitals (id, hospital_name, license_number, emergency_contact, verification_status)
        VALUES (NEW.id, v_full_name, 'HOSP-' || substr(NEW.id::text, 1, 6), COALESCE(v_phone, '+91-44-28290200'), 'verified')
        ON CONFLICT (id) DO UPDATE SET hospital_name = EXCLUDED.hospital_name, emergency_contact = EXCLUDED.emergency_contact;
    ELSIF v_role = 'blood_bank' THEN
        INSERT INTO public.blood_banks (id, bank_name, license_number, contact_phone, storage_capacity_units, verification_status)
        VALUES (NEW.id, v_full_name, 'BB-' || substr(NEW.id::text, 1, 6), COALESCE(v_phone, '+91-44-28554425'), 500, 'verified')
        ON CONFLICT (id) DO UPDATE SET bank_name = EXCLUDED.bank_name, contact_phone = EXCLUDED.contact_phone;
    END IF;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_sync_auth_user ON auth.users;
CREATE TRIGGER trg_sync_auth_user
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_auth_user_to_profile();
