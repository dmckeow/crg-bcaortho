process SPECIESRAX {
    tag "SpeciesRax"
    label 'process_generax'
    stageInMode 'copy' // Must stage in as copy, or OpenMPI will try to contantly read from S3 which causes problems.

    container "${ workflow.containerEngine == 'docker' ? 'arcadiascience/generax_19604b71:1.0.0': 
        workflow.containerEngine == 'apptainer' ? 'arcadiascience/generax_19604b71:1.0.0':
    '' }"

    publishDir(
        path: "${params.outdir}/${publish_subdir}/speciesrax",
        mode: params.publish_dir_mode,
        saveAs: { filename -> 
            if (filename.startsWith('reconciliations/') || 
                filename.startsWith('SpeciesRax/')) {
                return null
            }
            return filename.substring(filename.lastIndexOf('/')+1)
        }
    )

    input:
    file map_links       // Filepath to the generax gene-species map file
    file gene_trees      // Filepaths to the starting gene trees
    file alignments      // Filepaths to the gene family alignments
    file rooted_spp_tree // Filepath to the rooted asteroid species tree
    val publish_subdir

    output:
    path "*"                                          , emit: results
    path "species_trees/inferred_species_tree.newick" , emit: speciesrax_tree

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def starting_tree = (rooted_spp_tree && file(rooted_spp_tree).exists()) ? rooted_spp_tree : "MiniNJ"
    """
    # Recode selenocysteine as a gap character:
    # RAxML-NG (used under the hood by SpeciesRax and
    # GeneRax) cannot handle these. Even if rare,
    # their inclusion leads a number of gene families
    # to be excluded from analyses.
    sed -E -i '/>/!s/U/-/g' *.fa

    # Do the same for Pyrrolysine
    sed -E -i '/>/!s/O/-/g' *.fa

    # Do the same for stop codon
    sed -E -i '/>/!s/\\*/-/g' *.fa

    # Construct the family files for each gene family
    echo "[FAMILIES]" > speciesrax_orthogroup.families
    for msa in \$(ls *fa)
    do
        # Get the OG name
        og=\$(echo \$msa | sed -E 's/^(OG_[0-9]+|OG[0-9]+).*/\\1/')
        tree=\$(ls \${og}_*.treefile)

        # Populate the families file for this gene family for the
        # analysis with SpeciesRax
        # We will be using LG+G4+F for all gene families
        echo "- \${og}" >> speciesrax_orthogroup.families
        echo "starting_gene_tree = \${tree}" >> speciesrax_orthogroup.families
        echo "mapping = \${og}_map.link" >> speciesrax_orthogroup.families
        echo "alignment = \$msa" >> speciesrax_orthogroup.families
        echo "subst_model = LG+G4+F" >> speciesrax_orthogroup.families
    done


    mpiexec \\
        -np ${task.cpus} \\
        --allow-run-as-root \\
        --use-hwthread-cpus \\
        generax \\
        --species-tree $starting_tree \\
        --families speciesrax_orthogroup.families \\
        --prefix SpeciesRax \\
        --strategy SKIP \\
        --si-estimate-bl \\
        --per-species-rates \\
        $args

    # Remove the redundant result directory, moving everything into the
    # working directory, deleiting the meaningless reconciliations
    # directory and cleaning up
    cp -r SpeciesRax/* .
    
    """
}
