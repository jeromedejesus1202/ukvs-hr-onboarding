# UKVS HR Onboarding and Timetable

Shared employee onboarding and teaching timetable application for UKVS.

## Current State

- `index.html` contains the onboarding and shared timetable application.
- `supabase-client.js` connects authentication, people, carriers, schedules, drag-and-drop moves, and live updates to Supabase.
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

If the initial migration was installed before June 20, 2026, also run:

`supabase/migrations/202606200002_fix_empty_student_clash.sql`

This corrects an empty-result check that otherwise reports a student clash for every timetable placement.

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

Open `index.html` directly in a browser while connected to the internet. Sign in using a Supabase Authentication user. The public Supabase SDK is loaded from jsDelivr.

When one signed-in user changes the timetable, other signed-in users receive the database update through Supabase Realtime.

Timetable viewing tools include:

- searchable teacher and student views;
- year group, subject, and class-group filters;
- clash-only display;
- stable colours by subject, teacher, or year group;
- monthly workload totals;
- printable PDF views for a week, month, or complete academic year.

## Deployment

This static application can be deployed using GitHub Pages, Vercel, Netlify, or another static hosting provider.

For GitHub Pages:

1. Merge the implementation branch into `main`.
2. In GitHub, open **Settings > Pages**.
3. Select **Deploy from a branch** and choose `main` / root.
4. Add the resulting Pages URL to **Supabase > Authentication > URL Configuration > Redirect URLs**.
