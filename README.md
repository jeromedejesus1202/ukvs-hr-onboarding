# UKVS HR Onboarding and Timetable

Shared employee onboarding and teaching timetable application for UKVS.

## Current State

- `index.html` contains the current onboarding and timetable draft.
- The timetable currently continues to use browser storage until the Supabase client adapter is enabled.
- `supabase/migrations/202606200001_initial_timetable.sql` creates the shared cloud schema.
- `supabase-config.js` contains the public Supabase project URL and publishable key. These values are safe for browser use because access is enforced by authentication and Row Level Security.

## Supabase Setup

1. Open the Supabase project.
2. Go to **SQL Editor**.
3. Open `supabase/migrations/202606200001_initial_timetable.sql`.
4. Run the entire migration.
5. Go to **Authentication > Providers** and enable Email.
6. Create the first application user.
7. In **Table Editor > profiles**, change that user's role to `admin`.

Available roles:

- `admin`: manages users and all timetable data.
- `scheduler`: manages people, class carriers, and scheduling.
- `viewer`: read-only access.

Never commit the service-role key or database password.

## Data Model

- `profiles`: authenticated users and roles.
- `people`: teachers and students.
- `class_carriers`: Year 5 Maths A-style class definitions.
- `carrier_students`: students assigned to each carrier.
- `schedule_slots`: the current position of a carrier.
- `audit_log`: changes made by users.

The `move_carrier` database function:

- locks the carrier while it is being moved;
- checks its version to prevent accidental overwrites;
- checks teacher clashes;
- checks student clashes;
- writes an audit record.

## Local Preview

Open `index.html` directly in a browser. Cloud synchronization will be introduced in the next application integration step after the migration and authentication settings are confirmed.

## Deployment

This static application can be deployed using GitHub Pages, Vercel, Netlify, or another static hosting provider. GitHub Pages is suitable once authentication redirects are configured in Supabase.

