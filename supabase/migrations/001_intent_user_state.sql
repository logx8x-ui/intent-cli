create table if not exists public.intent_user_state (
    user_id uuid primary key references auth.users(id) on delete cascade,
    revision bigint not null default 0,
    payload jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default timezone('utc'::text, now())
);

alter table public.intent_user_state enable row level security;

drop policy if exists "Users can read their own Intent workspace" on public.intent_user_state;
create policy "Users can read their own Intent workspace"
on public.intent_user_state
for select
to authenticated
using ((select auth.uid()) is not null and (select auth.uid()) = user_id);

drop policy if exists "Users can create their own Intent workspace" on public.intent_user_state;
create policy "Users can create their own Intent workspace"
on public.intent_user_state
for insert
to authenticated
with check ((select auth.uid()) is not null and (select auth.uid()) = user_id);

drop policy if exists "Users can update their own Intent workspace" on public.intent_user_state;
create policy "Users can update their own Intent workspace"
on public.intent_user_state
for update
to authenticated
using ((select auth.uid()) is not null and (select auth.uid()) = user_id)
with check ((select auth.uid()) is not null and (select auth.uid()) = user_id);

drop policy if exists "Users can delete their own Intent workspace" on public.intent_user_state;
create policy "Users can delete their own Intent workspace"
on public.intent_user_state
for delete
to authenticated
using ((select auth.uid()) is not null and (select auth.uid()) = user_id);

revoke all on table public.intent_user_state from anon;
grant select, insert, update, delete on table public.intent_user_state to authenticated;
