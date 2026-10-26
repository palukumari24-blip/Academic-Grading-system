-- =====================================================================
--  File   : 04_analytics_queries.sql
--  Purpose: Reporting layer. Each query is labelled with the SQL
--           concept(s) it demonstrates:
--             [GF] group functions   [NS] nested subqueries
--             [CV] conversion funcs  [ST] string funcs
--             [WF] window functions
-- =====================================================================
USE academic_db;

-- =====================================================================
-- SECTION A : STUDENT PROFILES & DATA CLEANING   [ST][CV]
-- =====================================================================

-- A1. Standardised student directory: clean names, roll number, age, email domain
SELECT  fn_student_code(s.student_id)                                         AS roll_no,
        CONCAT(UPPER(TRIM(s.last_name)), ', ',
               CONCAT(UPPER(SUBSTRING(TRIM(s.first_name),1,1)),
                      LOWER(SUBSTRING(TRIM(s.first_name),2))))                AS student_name,
        LOWER(SUBSTRING_INDEX(s.email,'@',-1))                                AS email_domain,
        TIMESTAMPDIFF(YEAR, s.date_of_birth, CURDATE())                       AS age,
        DATE_FORMAT(s.enrollment_date, '%d-%b-%Y')                            AS enrolled,
        d.dept_name
FROM    students s
JOIN    departments d ON d.dept_id = s.dept_id
ORDER BY d.dept_code, s.last_name
LIMIT 15;

-- A2. Find records with dirty whitespace / inconsistent case in names
SELECT  student_id,
        CONCAT('[', first_name, '] [', last_name, ']')   AS raw_value,
        CHAR_LENGTH(first_name) - CHAR_LENGTH(TRIM(first_name)) AS first_name_extra_spaces,
        CHAR_LENGTH(last_name)  - CHAR_LENGTH(TRIM(last_name))  AS last_name_extra_spaces
FROM    students
WHERE   first_name <> TRIM(first_name)
   OR   last_name  <> TRIM(last_name)
   OR   last_name  = UPPER(last_name) COLLATE utf8mb4_bin;

-- A3. Initials, name length and masked email for a privacy-safe export
SELECT  student_id,
        CONCAT(LEFT(TRIM(first_name),1), LEFT(TRIM(last_name),1))             AS initials,
        CHAR_LENGTH(CONCAT(TRIM(first_name),' ',TRIM(last_name)))             AS name_length,
        CONCAT(LEFT(email,2), REPEAT('*', LOCATE('@',email)-3),
               SUBSTRING(email, LOCATE('@',email)))                           AS masked_email
FROM    students
ORDER BY student_id
LIMIT 10;

-- A4. Convert text -> date and number -> text   [CV]
SELECT  STR_TO_DATE('19-08-2024','%d-%m-%Y')                  AS parsed_date,
        CAST('87.456' AS DECIMAL(5,2))                        AS cast_decimal,
        CONVERT(87.456, CHAR)                                 AS number_to_text,
        CAST(CURDATE() AS CHAR)                               AS date_to_text,
        FORMAT(1234567.891, 2)                                AS formatted_number;

-- =====================================================================
-- SECTION B : WEIGHTED GPA CALCULATION   [GF]
-- =====================================================================

-- B1. Weighted course percentage for one student, shown step by step
SELECT  c.course_code,
        g.assessment_type,
        g.score,
        w.weight_pct,
        ROUND(g.score / g.max_score * w.weight_pct, 2)      AS weighted_points
FROM    registrations r
JOIN    exam_grades g          ON g.registration_id = r.registration_id
JOIN    assessment_weights w   ON w.assessment_type = g.assessment_type
JOIN    course_offerings o     ON o.offering_id = r.offering_id
JOIN    courses c              ON c.course_id = o.course_id
WHERE   r.student_id = 5 AND o.semester_id = 3
ORDER BY c.course_code, w.weight_pct;

-- B2. Semester GPA (credit-weighted) for every student-semester
SELECT  student_id, semester_id, sem_credits, sgpa
FROM    v_student_gpa_progress
ORDER BY student_id, semester_id
LIMIT 12;

-- B3. Cumulative GPA computed from scratch with group functions
--     CGPA = SUM(credits x grade points) / SUM(credits)
SELECT  s.student_id,
        CONCAT(TRIM(s.first_name),' ',TRIM(s.last_name))         AS student,
        SUM(g.credits)                                           AS credits_attempted,
        SUM(CASE WHEN g.is_pass=1 THEN g.credits ELSE 0 END)     AS credits_earned,
        ROUND(SUM(g.credits * g.grade_points) / SUM(g.credits),2) AS cgpa,
        ROUND(AVG(g.grade_points),2)                             AS simple_avg_gp,   -- unweighted, for contrast
        fn_gpa_standing(ROUND(SUM(g.credits*g.grade_points)/SUM(g.credits),2)) AS standing
FROM    students s
JOIN    v_course_grades g ON g.student_id = s.student_id
GROUP BY s.student_id, s.first_name, s.last_name
ORDER BY cgpa DESC
LIMIT 10;

-- B4. How different is weighted vs. simple GPA? (shows why weighting matters)
SELECT  COUNT(*)                                       AS students,
        ROUND(AVG(w_cgpa),3)                           AS avg_weighted_cgpa,
        ROUND(AVG(s_cgpa),3)                           AS avg_simple_cgpa,
        ROUND(MAX(ABS(w_cgpa - s_cgpa)),3)             AS max_difference
FROM (
        SELECT  student_id,
                SUM(credits*grade_points)/SUM(credits) AS w_cgpa,
                AVG(grade_points)                      AS s_cgpa
        FROM    v_course_grades
        GROUP BY student_id
     ) x;

-- B5. Department-wise GPA statistics   [GF]
SELECT  d.dept_name,
        COUNT(*)                         AS students,
        ROUND(AVG(ss.cgpa),2)            AS avg_cgpa,
        MIN(ss.cgpa)                     AS min_cgpa,
        MAX(ss.cgpa)                     AS max_cgpa,
        ROUND(STDDEV_POP(ss.cgpa),2)     AS std_dev
FROM    v_student_summary ss
JOIN    departments d ON d.dept_id = ss.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY avg_cgpa DESC;

-- =====================================================================
-- SECTION C : GRADE DISTRIBUTIONS   [GF][CV]
-- =====================================================================

-- C1. Letter-grade distribution per course, across all semesters
SELECT  c.course_code,
        COUNT(*)                                                       AS enrolled,
        SUM(g.letter_grade LIKE 'A%')                                  AS a_grades,
        SUM(g.letter_grade LIKE 'B%')                                  AS b_grades,
        SUM(g.letter_grade LIKE 'C%')                                  AS c_grades,
        SUM(g.letter_grade = 'D')                                      AS d_grades,
        SUM(g.letter_grade = 'F')                                      AS f_grades,
        CONCAT(ROUND(100*SUM(g.is_pass)/COUNT(*),1),'%')               AS pass_rate,
        ROUND(AVG(g.final_pct),1)                                      AS avg_pct
FROM    v_course_grades g
JOIN    courses c ON c.course_id = g.course_id
GROUP BY c.course_id, c.course_code
ORDER BY avg_pct DESC;

-- C2. Overall distribution with percentage share and a text histogram
SELECT  g.letter_grade,
        COUNT(*)                                                        AS cnt,
        CONCAT(ROUND(100*COUNT(*)/(SELECT COUNT(*) FROM v_course_grades),1),'%') AS share,
        RPAD('', ROUND(60*COUNT(*)/(SELECT COUNT(*) FROM v_course_grades)), '#') AS histogram
FROM    v_course_grades g
JOIN    grade_scale gs ON gs.letter_grade = g.letter_grade
GROUP BY g.letter_grade, gs.min_pct
ORDER BY gs.min_pct DESC;

-- C3. Courses where failure rate is above the university average   [NS]
SELECT  c.course_code, c.course_title,
        ROUND(100*SUM(1-g.is_pass)/COUNT(*),1) AS fail_rate_pct
FROM    v_course_grades g
JOIN    courses c ON c.course_id = g.course_id
GROUP BY c.course_id, c.course_code, c.course_title
HAVING  SUM(1-g.is_pass)/COUNT(*) >
        ( SELECT SUM(1-is_pass)/COUNT(*) FROM v_course_grades )
ORDER BY fail_rate_pct DESC;

-- C4. Grade distribution per term (pivot with conditional aggregation)
SELECT  sem.term_name,
        COUNT(*)                                   AS grades_issued,
        SUM(g.letter_grade IN ('A+','A','A-'))     AS A_band,
        SUM(g.letter_grade IN ('B+','B','B-'))     AS B_band,
        SUM(g.letter_grade IN ('C+','C'))          AS C_band,
        SUM(g.letter_grade IN ('D','F'))           AS D_F_band,
        ROUND(AVG(g.grade_points),2)               AS avg_grade_points
FROM    v_course_grades g
JOIN    semesters sem ON sem.semester_id = g.semester_id
GROUP BY sem.semester_id, sem.term_name
ORDER BY sem.semester_id;

-- C5. Instructor leniency check: average course % by instructor   [GF]
SELECT  i.full_name, COUNT(*) AS grades, ROUND(AVG(g.final_pct),1) AS avg_pct,
        ROUND(MAX(g.final_pct)-MIN(g.final_pct),1) AS spread
FROM    v_course_grades g
JOIN    course_offerings o ON o.offering_id = g.offering_id
JOIN    instructors i      ON i.instructor_id = o.instructor_id
GROUP BY i.instructor_id, i.full_name
HAVING  COUNT(*) >= 30
ORDER BY avg_pct DESC;

-- =====================================================================
-- SECTION D : ACADEMIC PROBATION & AT-RISK DETECTION   [NS][GF]
-- =====================================================================

-- D1. Students currently below the probation CGPA threshold (policy-driven subquery)
SELECT  ss.student_id,
        fn_student_code(ss.student_id)         AS roll_no,
        CONCAT(TRIM(ss.first_name),' ',TRIM(ss.last_name)) AS student,
        ss.cgpa, ss.sgpa, ss.cum_failed_credits
FROM    v_student_summary ss
WHERE   ss.cgpa < (SELECT policy_value FROM academic_policy WHERE policy_key='PROBATION_CGPA')
ORDER BY ss.cgpa;

-- D2. Three-tier risk classification for the latest semester
SELECT  CASE WHEN ss.cgpa < p.prob OR ss.cum_failed_credits >= p.maxfail THEN '1-Probation'
             WHEN ss.cgpa < p.risk                                         THEN '2-At Risk'
             ELSE '3-Good' END                      AS tier,
        COUNT(*)                                    AS students,
        ROUND(AVG(ss.cgpa),2)                       AS avg_cgpa
FROM    v_student_summary ss
CROSS JOIN (
        SELECT  MAX(CASE WHEN policy_key='PROBATION_CGPA'   THEN policy_value END) AS prob,
                MAX(CASE WHEN policy_key='AT_RISK_CGPA'     THEN policy_value END) AS risk,
                MAX(CASE WHEN policy_key='MAX_FAIL_CREDITS' THEN policy_value END) AS maxfail
        FROM    academic_policy ) p
GROUP BY tier
ORDER BY tier;

-- D3. Students whose GPA dropped in the latest semester vs their own cumulative average [NS]
SELECT  p.student_id, p.sgpa AS latest_sgpa,
        (SELECT ROUND(AVG(p2.sgpa),2) FROM v_student_gpa_progress p2
          WHERE p2.student_id = p.student_id AND p2.semester_id < p.semester_id) AS earlier_avg_sgpa
FROM    v_student_gpa_progress p
WHERE   p.semester_id = (SELECT MAX(semester_id) FROM semesters)
  AND   p.sgpa < (SELECT AVG(p2.sgpa) FROM v_student_gpa_progress p2
                   WHERE p2.student_id = p.student_id AND p2.semester_id < p.semester_id) - 0.5
ORDER BY p.sgpa;

-- D4. Students who failed in two or more courses in ANY single semester  [NS][GF]
SELECT  s.student_id, CONCAT(TRIM(s.first_name),' ',TRIM(s.last_name)) AS student
FROM    students s
WHERE   s.student_id IN (
            SELECT  student_id
            FROM    v_course_grades
            WHERE   is_pass = 0
            GROUP BY student_id, semester_id
            HAVING  COUNT(*) >= 2 );

-- D5. Probation candidates that are also repeat offenders (on the list in 2+ semesters)
--     (requires: CALL sp_refresh_probation(n) for each semester)
SELECT  pl.student_id, COUNT(*) AS semesters_flagged,
        GROUP_CONCAT(pl.risk_level ORDER BY pl.semester_id SEPARATOR ' > ') AS history
FROM    probation_log pl
GROUP BY pl.student_id
HAVING  COUNT(*) >= 2
ORDER BY semesters_flagged DESC, pl.student_id;

-- D6. Students on probation whose weakest course drags the average   [NS]
SELECT  g.student_id, c.course_code, g.final_pct
FROM    v_course_grades g
JOIN    courses c ON c.course_id = g.course_id
WHERE   g.final_pct = (SELECT MIN(g2.final_pct) FROM v_course_grades g2
                        WHERE g2.student_id = g.student_id)
  AND   g.student_id IN (SELECT student_id FROM v_student_summary WHERE cgpa < 2.00)
ORDER BY g.final_pct;

-- =====================================================================
-- SECTION E : TOP PERCENTILE PER DEPARTMENT   [NS][WF]
-- =====================================================================

-- E1. Percentile rank of each student inside their department (window functions)
SELECT  d.dept_code,
        CONCAT(TRIM(ss.first_name),' ',TRIM(ss.last_name))               AS student,
        ss.cgpa,
        RANK()        OVER (PARTITION BY ss.dept_id ORDER BY ss.cgpa DESC) AS dept_rank,
        ROUND(100*PERCENT_RANK() OVER (PARTITION BY ss.dept_id ORDER BY ss.cgpa),1) AS percentile
FROM    v_student_summary ss
JOIN    departments d ON d.dept_id = ss.dept_id
ORDER BY d.dept_code, dept_rank
LIMIT 20;

-- E2. Same idea WITHOUT window functions - pure correlated nested subquery
--     percentile = share of department peers with a strictly lower CGPA
SELECT  d.dept_code, ss.student_id, ss.cgpa,
        ROUND(100 * (SELECT COUNT(*) FROM v_student_summary x
                      WHERE x.dept_id = ss.dept_id AND x.cgpa < ss.cgpa)
                  / (SELECT COUNT(*) FROM v_student_summary y
                      WHERE y.dept_id = ss.dept_id), 1)   AS percentile
FROM    v_student_summary ss
JOIN    departments d ON d.dept_id = ss.dept_id
ORDER BY d.dept_code, percentile DESC
LIMIT 20;

-- E3. HONOURS LIST: students at/above the policy percentile in their department
SELECT  dept_code, student, cgpa, dept_rank, percentile
FROM (
        SELECT  d.dept_code,
                CONCAT(TRIM(ss.first_name),' ',TRIM(ss.last_name))          AS student,
                ss.cgpa,
                RANK() OVER (PARTITION BY ss.dept_id ORDER BY ss.cgpa DESC) AS dept_rank,
                ROUND(100*PERCENT_RANK() OVER (PARTITION BY ss.dept_id ORDER BY ss.cgpa),1) AS percentile
        FROM    v_student_summary ss
        JOIN    departments d ON d.dept_id = ss.dept_id
     ) ranked
WHERE   percentile >= (SELECT policy_value FROM academic_policy WHERE policy_key='TOP_PERCENTILE')
ORDER BY dept_code, dept_rank;

-- E4. Department topper(s): students whose CGPA equals the dept maximum   [NS]
SELECT  d.dept_name, ss.student_id, ss.first_name, ss.last_name, ss.cgpa
FROM    v_student_summary ss
JOIN    departments d ON d.dept_id = ss.dept_id
WHERE   ss.cgpa = (SELECT MAX(x.cgpa) FROM v_student_summary x WHERE x.dept_id = ss.dept_id)
ORDER BY d.dept_name;

-- E5. Quartiles per department using NTILE
SELECT  dept_code, quartile, COUNT(*) AS students,
        MIN(cgpa) AS q_min, MAX(cgpa) AS q_max
FROM (
        SELECT  d.dept_code, ss.cgpa,
                NTILE(4) OVER (PARTITION BY ss.dept_id ORDER BY ss.cgpa DESC) AS quartile
        FROM    v_student_summary ss JOIN departments d ON d.dept_id = ss.dept_id
     ) q
GROUP BY dept_code, quartile
ORDER BY dept_code, quartile;

-- E6. Best student in each course (highest final %, ties kept)   [NS]
SELECT  c.course_code, g.student_id, g.final_pct, g.letter_grade, sem.term_name
FROM    v_course_grades g
JOIN    courses c     ON c.course_id = g.course_id
JOIN    semesters sem ON sem.semester_id = g.semester_id
WHERE   g.final_pct = (SELECT MAX(g2.final_pct) FROM v_course_grades g2
                        WHERE g2.course_id = g.course_id)
ORDER BY c.course_code;

-- =====================================================================
-- SECTION F : OPERATIONS & MANAGEMENT SUMMARIES   [GF][NS]
-- =====================================================================

-- F1. Semester workload: registrations, withdrawals and credit load
SELECT  sem.term_name,
        COUNT(*)                                           AS registrations,
        SUM(r.status='Withdrawn')                          AS withdrawals,
        CONCAT(ROUND(100*SUM(r.status='Withdrawn')/COUNT(*),1),'%') AS withdrawal_rate,
        COUNT(DISTINCT r.student_id)                       AS active_students,
        ROUND(SUM(c.credits)/COUNT(DISTINCT r.student_id),1) AS avg_credit_load
FROM    registrations r
JOIN    course_offerings o ON o.offering_id = r.offering_id
JOIN    courses c          ON c.course_id   = o.course_id
JOIN    semesters sem      ON sem.semester_id = o.semester_id
GROUP BY sem.semester_id, sem.term_name
ORDER BY sem.semester_id;

-- F2. Cross-department enrolment (students taking other departments' courses)
SELECT  sd.dept_code AS student_dept, cd.dept_code AS course_dept, COUNT(*) AS enrolments
FROM    registrations r
JOIN    students s          ON s.student_id = r.student_id
JOIN    departments sd      ON sd.dept_id = s.dept_id
JOIN    course_offerings o  ON o.offering_id = r.offering_id
JOIN    courses c           ON c.course_id = o.course_id
JOIN    departments cd      ON cd.dept_id = c.dept_id
WHERE   sd.dept_id <> cd.dept_id
GROUP BY sd.dept_code, cd.dept_code
ORDER BY enrolments DESC
LIMIT 10;

-- F3. Students who have never failed a course   [NS]
SELECT  COUNT(*) AS clean_record_students
FROM    students s
WHERE   s.student_id IN (SELECT student_id FROM v_course_grades)
  AND   s.student_id NOT IN (SELECT student_id FROM v_course_grades WHERE is_pass = 0);

-- F4. Students scoring above the average of THEIR OWN department in the Final exam [NS]
SELECT  s.dept_id, COUNT(DISTINCT s.student_id) AS students_above_dept_avg
FROM    students s
JOIN    registrations r ON r.student_id = s.student_id
JOIN    exam_grades g   ON g.registration_id = r.registration_id AND g.assessment_type='Final'
WHERE   g.score > (SELECT AVG(g2.score)
                     FROM students s2
                     JOIN registrations r2 ON r2.student_id = s2.student_id
                     JOIN exam_grades g2   ON g2.registration_id = r2.registration_id
                                          AND g2.assessment_type='Final'
                    WHERE s2.dept_id = s.dept_id)
GROUP BY s.dept_id;

-- F5. Data-quality audit: registrations marked Completed but missing components
SELECT  COUNT(*) AS completed_with_missing_marks
FROM    v_course_results WHERE components_graded < 3;
