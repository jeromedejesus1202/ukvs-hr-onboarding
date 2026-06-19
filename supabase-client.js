(function () {
  const config = window.UKVS_SUPABASE || {};
  const factory = window.supabase && window.supabase.createClient;
  const client = factory && config.url && config.publishableKey
    ? factory(config.url, config.publishableKey)
    : null;

  function requireClient() {
    if (!client) throw new Error('Supabase client is not configured.');
    return client;
  }

  function monthParts(monthKey) {
    const [year, month] = monthKey.split('-').map(Number);
    return { year, month, academicYearStart: month >= 9 ? year : year - 1 };
  }

  function toPerson(row) {
    return {
      id: row.id,
      name: row.name,
      type: row.person_type,
      yearLevel: row.year_level || '',
      yearGroup: row.year_group || ''
    };
  }

  function toSession(row) {
    const slot = Array.isArray(row.schedule_slots) ? row.schedule_slots[0] : row.schedule_slots;
    return {
      id: row.id,
      monthKey: `${row.month >= 9 ? row.academic_year_start : row.academic_year_start + 1}-${String(row.month).padStart(2, '0')}`,
      week: slot ? slot.week : null,
      day: slot ? slot.day : null,
      time: slot ? String(slot.start_time).slice(0, 5) : '',
      teacherId: row.teacher_id,
      subject: row.subject,
      yearLevel: row.year_level || '',
      yearGroup: row.year_group,
      classGroup: row.class_group,
      studentIds: (row.carrier_students || []).map(item => item.student_id),
      scheduled: !!slot,
      version: row.version
    };
  }

  async function loadState() {
    const db = requireClient();
    const [peopleResult, carrierResult] = await Promise.all([
      db.from('people').select('*').eq('active', true).order('name'),
      db.from('class_carriers')
        .select('*, carrier_students(student_id), schedule_slots(week, day, start_time)')
        .order('created_at')
    ]);
    if (peopleResult.error) throw peopleResult.error;
    if (carrierResult.error) throw carrierResult.error;
    return {
      people: (peopleResult.data || []).map(toPerson),
      sessions: (carrierResult.data || []).map(toSession)
    };
  }

  async function addPerson(person) {
    const db = requireClient();
    const { data, error } = await db.from('people').insert({
      name: person.name,
      person_type: person.type,
      year_level: person.yearLevel || null,
      year_group: person.yearGroup || null
    }).select().single();
    if (error) throw error;
    return toPerson(data);
  }

  async function deletePerson(id) {
    const db = requireClient();
    const { error } = await db.from('people').delete().eq('id', id);
    if (error) throw error;
  }

  async function saveCarrier(session) {
    const db = requireClient();
    const period = monthParts(session.monthKey);
    const carrier = {
      subject: session.subject,
      year_level: session.yearLevel || null,
      year_group: session.yearGroup,
      class_group: session.classGroup,
      teacher_id: session.teacherId,
      academic_year_start: period.academicYearStart,
      month: period.month
    };

    let id = session.id;
    let version = session.version || 1;
    if (id && /^[0-9a-f-]{36}$/i.test(id)) {
      const result = await db.from('class_carriers').update({
        ...carrier,
        version: version + 1
      }).eq('id', id).eq('version', version).select().single();
      if (result.error) throw result.error;
      version = result.data.version;
      const clear = await db.from('carrier_students').delete().eq('carrier_id', id);
      if (clear.error) throw clear.error;
    } else {
      const result = await db.from('class_carriers').insert(carrier).select().single();
      if (result.error) throw result.error;
      id = result.data.id;
      version = result.data.version;
    }

    if (session.studentIds.length) {
      const enrolment = await db.from('carrier_students').insert(
        session.studentIds.map(studentId => ({ carrier_id: id, student_id: studentId }))
      );
      if (enrolment.error) throw enrolment.error;
    }

    if (session.scheduled) {
      const moved = await db.rpc('move_carrier', {
        p_carrier_id: id,
        p_week: session.week,
        p_day: session.day,
        p_start_time: session.time,
        p_expected_version: version
      });
      if (moved.error) throw moved.error;
      version = moved.data.version;
    } else {
      const slot = await db.from('schedule_slots').delete().eq('carrier_id', id);
      if (slot.error) throw slot.error;
    }
    return { ...session, id, version };
  }

  async function moveCarrier(session, week, day, time) {
    const db = requireClient();
    const { data, error } = await db.rpc('move_carrier', {
      p_carrier_id: session.id,
      p_week: week,
      p_day: day,
      p_start_time: time,
      p_expected_version: session.version
    });
    if (error) throw error;
    return { ...session, week, day, time, scheduled: true, version: data.version };
  }

  async function unscheduleCarrier(session) {
    const db = requireClient();
    const slot = await db.from('schedule_slots').delete().eq('carrier_id', session.id);
    if (slot.error) throw slot.error;
    const carrier = await db.from('class_carriers').update({
      version: (session.version || 1) + 1
    }).eq('id', session.id).eq('version', session.version || 1).select().single();
    if (carrier.error) throw carrier.error;
    return { ...session, week: null, day: null, time: '', scheduled: false, version: carrier.data.version };
  }

  async function deleteCarrier(id) {
    const db = requireClient();
    const { error } = await db.from('class_carriers').delete().eq('id', id);
    if (error) throw error;
  }

  async function signIn(email, password) {
    const { data, error } = await requireClient().auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  }

  async function signOut() {
    const { error } = await requireClient().auth.signOut();
    if (error) throw error;
  }

  async function session() {
    const { data, error } = await requireClient().auth.getSession();
    if (error) throw error;
    return data.session;
  }

  function onAuthChange(callback) {
    return requireClient().auth.onAuthStateChange((_event, currentSession) => callback(currentSession));
  }

  function subscribe(callback) {
    const channel = requireClient().channel('ukvs-timetable-live');
    ['people', 'class_carriers', 'carrier_students', 'schedule_slots'].forEach(table => {
      channel.on('postgres_changes', { event: '*', schema: 'public', table }, callback);
    });
    channel.subscribe();
    return channel;
  }

  window.UKVSCloud = {
    client,
    loadState,
    addPerson,
    deletePerson,
    saveCarrier,
    moveCarrier,
    unscheduleCarrier,
    deleteCarrier,
    signIn,
    signOut,
    session,
    onAuthChange,
    subscribe
  };
})();
