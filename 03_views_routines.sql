-- =====================================================================
--  File   : 03_views_routines.sql
--  Purpose: Business logic layer - views, stored functions, stored
--           procedures and a trigger. Everything else (reports, tests)
--           is built on top of these objects.
-- =====================================================================
USE academic_db;

-- ---------------------------------------------------------------------
-- VIEW 1: v_course_results
--   Weighted course percentage per completed registration.
--   final_pct = SUM(score% * weight) / SUM(weight)
--   (dividing by the weights actually present keeps partial results fair)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_course_results AS
SELECT  r.registration_id,
        r.student_id,
        o.offering_id,
        o.semester_id,
        c.course_id,
        c.dept_id        AS course_dept_id,
        c.credits,
        ROUND( SUM( (g.score / g.max_score) * 100 * w.weight_pct )
               / SUM(w.weight_pct), 2 )              AS final_pct,
        COUNT(g.grade_id)                            AS components_graded
FROM    registrations      r
JOIN    course_offerings   o ON o.offering_id     = r.offering_id
JOIN    courses            c ON c.course_id       = o.course_id
JOIN    exam_grades        g ON g.registration_id = r.registration_id
JOIN    assessment_weights w ON w.assessment_type = g.assessment_type
WHERE   r.status = 'Completed'
GROUP BY r.registration_id, r.student_id, o.offering_id, o.semester_id,
         c.course_id, c.dept_id, c.credits;

-- ---------------------------------------------------------------------
-- VIEW 2: v_course_grades  (adds letter grade, grade points, pass flag)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_course_grades AS
SELECT  cr.*,
        gs.letter_grade,
        gs.grade_points,
        gs.is_pass,
        cr.credits * gs.grade_points AS quality_points
FROM    v_course_results cr
JOIN    grade_scale      gs
        ON cr.final_pct BETWEEN gs.min_pct AND gs.max_pct;

-- ---------------------------------------------------------------------
-- VIEW 3: v_student_gpa_progress
--   One row per student per semester with:
--     sgpa  = credit-weighted GPA of that semester
--     cgpa  = credit-weighted GPA of everything up to and including it
--     prev_sgpa, cum_failed_credits (for probation rules)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_student_gpa_progress AS
SELECT  t.*,
        ROUND( SUM(t.sem_quality_pts) OVER w_cum
               / SUM(t.sem_credits)   OVER w_cum, 2 )     AS cgpa,
        SUM(t.sem_failed_credits)     OVER w_cum          AS cum_failed_credits,
        LAG(t.sgpa) OVER w_seq                            AS prev_sgpa
FROM (
        SELECT  student_id,
                semester_id,
                SUM(credits)                              AS sem_credits,
                SUM(quality_points)                       AS sem_quality_pts,
                SUM(CASE WHEN is_pass = 0 THEN credits ELSE 0 END)
                                                          AS sem_failed_credits,
                ROUND(SUM(quality_points) / SUM(credits), 2) AS sgpa
        FROM    v_course_grades
        GROUP BY student_id, semester_id
     ) t
WINDOW w_cum AS (PARTITION BY t.student_id ORDER BY t.semester_id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
       w_seq AS (PARTITION BY t.student_id ORDER BY t.semester_id);

-- ---------------------------------------------------------------------
-- VIEW 4: v_student_summary  (latest standing for every student)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_student_summary AS
SELECT  s.student_id,
        s.first_name, s.last_name,
        s.dept_id,
        p.semester_id   AS last_semester_id,
        p.sem_credits   AS last_sem_credits,
        p.sgpa,
        p.cgpa,
        p.cum_failed_credits
FROM    students s
JOIN    v_student_gpa_progress p
        ON  p.student_id  = s.student_id
        AND p.semester_id = ( SELECT MAX(p2.semester_id)
                              FROM   v_student_gpa_progress p2
                              WHERE  p2.student_id = s.student_id );

-- ---------------------------------------------------------------------
-- FUNCTION: fn_student_code
--   Builds a roll number using string + conversion functions
--   e.g. CSE-2024-0007
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_student_code;
DELIMITER $$
CREATE FUNCTION fn_student_code(p_student_id INT UNSIGNED)
RETURNS VARCHAR(20)
READS SQL DATA
BEGIN
    DECLARE v_code VARCHAR(20);
    SELECT CONCAT(d.dept_code, '-', DATE_FORMAT(s.enrollment_date, '%Y'),
                  '-', LPAD(CAST(s.student_id AS CHAR), 4, '0'))
    INTO   v_code
    FROM   students s JOIN departments d ON d.dept_id = s.dept_id
    WHERE  s.student_id = p_student_id;
    RETURN v_code;
END$$

-- ---------------------------------------------------------------------
-- FUNCTION: fn_gpa_standing  - maps a CGPA onto an academic standing
--   thresholds are read from academic_policy (no magic numbers)
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_gpa_standing$$
CREATE FUNCTION fn_gpa_standing(p_cgpa DECIMAL(4,2))
RETURNS VARCHAR(20)
READS SQL DATA
BEGIN
    DECLARE v_prob DECIMAL(5,2);
    DECLARE v_risk DECIMAL(5,2);
    SELECT policy_value INTO v_prob FROM academic_policy WHERE policy_key = 'PROBATION_CGPA';
    SELECT policy_value INTO v_risk FROM academic_policy WHERE policy_key = 'AT_RISK_CGPA';
    RETURN CASE
             WHEN p_cgpa IS NULL   THEN 'No Data'
             WHEN p_cgpa < v_prob  THEN 'Probation'
             WHEN p_cgpa < v_risk  THEN 'At Risk'
             WHEN p_cgpa >= 3.70   THEN 'Distinction'
             WHEN p_cgpa >= 3.00   THEN 'Good Standing'
             ELSE 'Satisfactory'
           END;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE: sp_refresh_probation(semester)
--   Re-evaluates every student for the given semester and (re)writes
--   probation_log.  Idempotent: safe to run many times.
--   Probation : CGPA < PROBATION_CGPA  OR  failed credits >= MAX_FAIL_CREDITS
--   At Risk   : CGPA < AT_RISK_CGPA
--   Watch     : SGPA fell by >= SEM_GPA_DROP versus previous semester
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_refresh_probation$$
CREATE PROCEDURE sp_refresh_probation(IN p_semester_id TINYINT UNSIGNED)
BEGIN
    DECLARE v_prob DECIMAL(5,2);
    DECLARE v_risk DECIMAL(5,2);
    DECLARE v_drop DECIMAL(5,2);
    DECLARE v_fail DECIMAL(5,2);

    SELECT policy_value INTO v_prob FROM academic_policy WHERE policy_key = 'PROBATION_CGPA';
    SELECT policy_value INTO v_risk FROM academic_policy WHERE policy_key = 'AT_RISK_CGPA';
    SELECT policy_value INTO v_drop FROM academic_policy WHERE policy_key = 'SEM_GPA_DROP';
    SELECT policy_value INTO v_fail FROM academic_policy WHERE policy_key = 'MAX_FAIL_CREDITS';

    DELETE FROM probation_log WHERE semester_id = p_semester_id;

    INSERT INTO probation_log (student_id, semester_id, cgpa, sgpa, risk_level, reason)
    SELECT  student_id, semester_id, cgpa, sgpa,
            CASE WHEN cgpa < v_prob OR cum_failed_credits >= v_fail THEN 'Probation'
                 WHEN cgpa < v_risk                                 THEN 'At Risk'
                 ELSE 'Watch' END,
            CASE WHEN cgpa < v_prob
                      THEN CONCAT('CGPA ', cgpa, ' is below ', v_prob)
                 WHEN cum_failed_credits >= v_fail
                      THEN CONCAT(cum_failed_credits, ' failed credits (limit ', v_fail, ')')
                 WHEN cgpa < v_risk
                      THEN CONCAT('CGPA ', cgpa, ' is below ', v_risk)
                 ELSE CONCAT('SGPA fell from ', prev_sgpa, ' to ', sgpa) END
    FROM    v_student_gpa_progress
    WHERE   semester_id = p_semester_id
      AND ( cgpa < v_risk
            OR cum_failed_credits >= v_fail
            OR (prev_sgpa IS NOT NULL AND prev_sgpa - sgpa >= v_drop) );

    SELECT risk_level, COUNT(*) AS students
    FROM   probation_log WHERE semester_id = p_semester_id
    GROUP BY risk_level
    ORDER BY FIELD(risk_level, 'Probation', 'At Risk', 'Watch');
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE: sp_transcript(student)  - official-style transcript
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_transcript$$
CREATE PROCEDURE sp_transcript(IN p_student_id INT UNSIGNED)
BEGIN
    SELECT  fn_student_code(s.student_id)                         AS student_code,
            CONCAT(UPPER(TRIM(s.last_name)), ', ',
                   CONCAT(UPPER(LEFT(TRIM(s.first_name),1)),
                          LOWER(SUBSTRING(TRIM(s.first_name),2)))) AS student_name,
            d.dept_name,
            DATE_FORMAT(s.enrollment_date, '%d %b %Y')            AS enrolled_on
    FROM    students s JOIN departments d ON d.dept_id = s.dept_id
    WHERE   s.student_id = p_student_id;

    SELECT  sem.term_name, c.course_code, c.course_title, c.credits,
            g.final_pct, g.letter_grade, g.grade_points
    FROM    v_course_grades g
    JOIN    courses   c   ON c.course_id   = g.course_id
    JOIN    semesters sem ON sem.semester_id = g.semester_id
    WHERE   g.student_id = p_student_id
    ORDER BY sem.semester_id, c.course_code;

    SELECT  sem.term_name, p.sem_credits AS credits, p.sgpa, p.cgpa,
            fn_gpa_standing(p.cgpa) AS standing
    FROM    v_student_gpa_progress p
    JOIN    semesters sem ON sem.semester_id = p.semester_id
    WHERE   p.student_id = p_student_id
    ORDER BY p.semester_id;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE: sp_register_student(student, offering)
--   Transactional registration with validation (SIGNAL on violation)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_register_student$$
CREATE PROCEDURE sp_register_student(IN p_student_id INT UNSIGNED,
                                     IN p_offering_id INT UNSIGNED)
BEGIN
    DECLARE v_sem      TINYINT UNSIGNED;
    DECLARE v_credits  INT;
    DECLARE v_new_cr   INT;
    DECLARE v_max      DECIMAL(5,2);
    DECLARE v_status   VARCHAR(20);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT status INTO v_status FROM students WHERE student_id = p_student_id;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    ELSEIF v_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only Active students can register';
    END IF;

    SELECT o.semester_id, c.credits INTO v_sem, v_new_cr
    FROM   course_offerings o JOIN courses c ON c.course_id = o.course_id
    WHERE  o.offering_id = p_offering_id;
    IF v_sem IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown course offering';
    END IF;

    SELECT policy_value INTO v_max FROM academic_policy WHERE policy_key = 'MAX_SEM_CREDITS';

    START TRANSACTION;
    SELECT COALESCE(SUM(c.credits), 0) INTO v_credits
    FROM   registrations r
    JOIN   course_offerings o ON o.offering_id = r.offering_id
    JOIN   courses c          ON c.course_id   = o.course_id
    WHERE  r.student_id = p_student_id AND o.semester_id = v_sem
      AND  r.status <> 'Withdrawn'
    FOR UPDATE;

    IF v_credits + v_new_cr > v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Credit limit for the semester exceeded';
    END IF;

    INSERT INTO registrations (student_id, offering_id, registered_on, status)
    VALUES (p_student_id, p_offering_id, CURDATE(), 'Registered');
    COMMIT;
    SELECT LAST_INSERT_ID() AS registration_id, v_credits + v_new_cr AS semester_credits_now;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURE: sp_record_grade(registration, type, score)  - upsert a mark
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_record_grade$$
CREATE PROCEDURE sp_record_grade(IN p_registration_id INT UNSIGNED,
                                 IN p_type VARCHAR(12),
                                 IN p_score DECIMAL(5,2))
BEGIN
    INSERT INTO exam_grades (registration_id, assessment_type, score, graded_on)
    VALUES (p_registration_id, p_type, p_score, CURDATE())
    ON DUPLICATE KEY UPDATE score = VALUES(score), graded_on = CURDATE();
END$$

-- ---------------------------------------------------------------------
-- TRIGGER: a Final exam mark completes the registration
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_final_completes_registration$$
CREATE TRIGGER trg_final_completes_registration
AFTER INSERT ON exam_grades
FOR EACH ROW
BEGIN
    IF NEW.assessment_type = 'Final' THEN
        UPDATE registrations SET status = 'Completed'
        WHERE  registration_id = NEW.registration_id AND status = 'Registered';
    END IF;
END$$
DELIMITER ;
